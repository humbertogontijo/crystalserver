-- Pack tracking for cave walks: which monsters engaged the party (native aggro on a
-- member), whether they still come, and what the lure counts. Monster movement is
-- left to the engine. Expedition sessions track every instance-spawn monster
-- (ExpeditionPack spawn hook); open-world runs adopt only monsters that target a
-- member (CavebotPack.adoptEngaged) — a public layer's other monsters belong to other
-- players.

CavebotPack = CavebotPack or {}

local geo = CombatGeo
local chebyshev, nowMs = geo.chebyshev, geo.nowMs

-- monsterId -> open run id (adopted monsters; expedition kills go through ExpeditionPack)
local owners = {}

--- Stop tracking a far / stalled monster (it is not re-tracked for a while).
function CavebotPack.release(run, mid)
	run.engaged[mid] = nil
	run.releasedUntil[mid] = nowMs() + 2 * CavebotConfig.PULL_STALL_MS
end

function CavebotPack.targetsMember(monster, members)
	local target = monster.getTarget and monster:getTarget() or nil
	return target ~= nil and members[target:getId()] == true
end
local targetsMember = CavebotPack.targetsMember

--- Track a monster that took a party member as target (native aggro).
function CavebotPack.engage(run, mid, monster, anchorPos)
	local now = nowMs()
	run.engaged[mid] = { since = now, dist = chebyshev(monster:getPosition(), anchorPos), progressAt = now, hp = monster:getHealth() }
end

--- Taking damage, or chasing a member (`chasing`) and on the anchor's screen (trailing a
--- walk counts), closing in, next to the anchor or next to its target. A monster that
--- dropped the party for someone else makes no progress.
function CavebotPack.packProgress(state, monster, dist, chasing, onScreen)
	local hp = monster:getHealth()
	if hp < (state.hp or hp) then
		return true
	end
	if not chasing then
		return false
	end
	if onScreen or dist < (state.dist or math.huge) or dist <= 1 then
		return true
	end
	local target = monster:getTarget()
	return target ~= nil and chebyshev(monster:getPosition(), target:getPosition()) <= 1
end

--- Update engaged monsters, drop stalled / far ones, and engage tracked monsters that
--- aggroed the party. `members`: set of member ids.
function CavebotPack.tickPack(run, anchorPos, members)
	local now = nowMs()
	local releaseRadius = CavebotConfig.RELEASE_RADIUS
	local stallMs = CavebotConfig.PULL_STALL_MS

	-- Gone without a death event (despawn, teleport, instance clear); deaths are counted in onDeath.
	for mid in pairs(run.tracked) do
		if not Monster(mid) then
			run.tracked[mid] = nil
			run.engaged[mid] = nil
			run.alive = math.max(0, (run.alive or 1) - 1)
			owners[mid] = nil
		end
	end

	for mid, state in pairs(run.engaged) do
		local monster = Monster(mid)
		if not monster or monster:getHealth() <= 0 then
			run.engaged[mid] = nil
		else
			local mpos = monster:getPosition()
			local dist = chebyshev(mpos, anchorPos)
			local chasing = targetsMember(monster, members)
			-- A monster chasing a trailing member is measured from that member too.
			local target = chasing and monster:getTarget() or nil
			local near = target and math.min(dist, chebyshev(mpos, target:getPosition())) or dist
			if near > releaseRadius then
				CavebotPack.release(run, mid)
			else
				if CavebotPack.packProgress(state, monster, dist, chasing, geo.isInViewport(anchorPos, mpos)) then
					state.progressAt = now
				end
				state.dist = dist
				state.hp = monster:getHealth()
				if now - (state.progressAt or now) > stallMs then
					CavebotPack.release(run, mid)
				end
			end
		end
	end

	-- Engage tracked monsters that aggroed a member (released ones wait out their ban).
	for mid in pairs(run.tracked) do
		if not run.engaged[mid] and (run.releasedUntil[mid] or 0) <= now then
			local monster = Monster(mid)
			if monster and targetsMember(monster, members) then
				CavebotPack.engage(run, mid, monster, anchorPos)
			end
		end
	end
end

--- No standable tile around `pos`: a monster there (an island spawn) never comes.
function CavebotPack.sealedIn(pos)
	for _, off in ipairs(geo.NEIGHBOUR_OFFSETS) do
		if geo.tileStandable(Position(pos.x + off[1], pos.y + off[2], pos.z)) then
			return false
		end
	end
	return true
end
local sealedIn = CavebotPack.sealedIn

--- Engaged monsters chasing a party member (any member, not only the anchor) on the
--- anchor's floor that the party can see and that can still come: on the anchor's screen
--- or on the screen of the member they chase, alive, not sealed in, and (unless
--- `includeStuck`) not given up on by the lure walk (`lagStuckUntil` on their engaged
--- entry). Off-screen chasers are still tracked, just never counted or waited for.
--- `members`: set of member ids. Returns { { monster, state, target }, ... }.
function CavebotPack.chasers(run, members, anchorPos, now, includeStuck)
	local z = anchorPos.z
	local out = {}
	for mid, state in pairs(run.engaged or {}) do
		if includeStuck or (state.lagStuckUntil or 0) <= now then
			local monster = Monster(mid)
			local target = monster and monster:getHealth() > 0 and monster:getTarget() or nil
			if target and members[target:getId()] then
				local mpos, tpos = monster:getPosition(), target:getPosition()
				local inSight = geo.isInViewport(anchorPos, mpos) or geo.isInViewport(tpos, mpos)
				if mpos.z == z and tpos.z == z and inSight and not sealedIn(mpos) then
					out[#out + 1] = { monster = monster, state = state, target = target }
				end
			end
		end
	end
	return out
end

local function memberPlayers(members, anchor)
	local players = {}
	for id in pairs(members) do
		local member = Player(id)
		if member then
			players[#players + 1] = member
		end
	end
	if #players == 0 then
		players[1] = anchor
	end
	return players
end

--- What the lure counts: live monsters (not summons) on the anchor's screen that target
--- a member and that some member can attack, plus every chaser (`CavebotPack.chasers`)
--- on a member off that screen but on that member's screen, each once. An idle monster or one on another player
--- never follows the walk; one behind a wall (no clear shot from anyone) or sealed on an
--- island never arrives, so counting them would hold a halt forever.
--- `members`: set of member ids. Returns the count and the load: their summed health
--- fractions (two monsters at half health weigh as one).
function CavebotPack.lureCount(run, anchor, members)
	local pos = anchor:getPosition()
	local vx, vy = geo.VIEWPORT_X, geo.VIEWPORT_Y
	local players = memberPlayers(members, anchor)
	local n, load, counted = 0, 0, {}
	local function count(monster)
		counted[monster:getId()] = true
		n = n + 1
		load = load + monster:getHealth() / math.max(1, monster:getMaxHealth())
	end
	for _, creature in ipairs(Game.getSpectators(pos, false, false, vx, vx, vy, vy, anchor:getInstanceId())) do
		if creature:isMonster() and creature:getHealth() > 0 and not creature:getMaster() and targetsMember(creature, members) and not sealedIn(creature:getPosition()) then
			for _, member in ipairs(players) do
				if CombatAutomation.isValidAttackTarget(member, creature) then
					count(creature)
					break
				end
			end
		end
	end
	for _, chaser in ipairs(CavebotPack.chasers(run, members, pos, nowMs())) do
		if not counted[chaser.monster:getId()] then
			count(chaser.monster)
		end
	end
	return n, load
end

-- ---------------------------------------------------------------------------
-- Open-world runs: aggro-based tracking
-- ---------------------------------------------------------------------------

--- Track monsters (not summons) on a member's screen that target a member; drop
--- tracked monsters that are neither engaged nor on the party any more.
function CavebotPack.adoptEngaged(run, members)
	local vx, vy = geo.VIEWPORT_X, geo.VIEWPORT_Y
	local seen = {}
	for id in pairs(members) do
		local member = Player(id)
		if member then
			for _, creature in ipairs(Game.getSpectators(member:getPosition(), false, false, vx, vx, vy, vy, member:getInstanceId())) do
				if creature:isMonster() and creature:getHealth() > 0 and not creature:getMaster() and targetsMember(creature, members) then
					local mid = creature:getId()
					seen[mid] = true
					if not run.tracked[mid] then
						run.tracked[mid] = true
						owners[mid] = run.id
						creature:registerEvent("CavebotMonsterDeath")
					end
				end
			end
		end
	end
	for mid in pairs(run.tracked) do
		if not seen[mid] and not run.engaged[mid] then
			run.tracked[mid] = nil
			owners[mid] = nil
		end
	end
end

--- CavebotMonsterDeath: an adopted monster died.
function CavebotPack.onMonsterDeath(creature)
	local mid = creature and creature:getId()
	local runId = mid and owners[mid]
	if not runId then
		return
	end
	owners[mid] = nil
	local run = CavebotService and CavebotService.getRun(runId)
	if not run then
		return
	end
	run.engaged[mid] = nil
	run.lastKillAt = nowMs()
	if run.tracked[mid] then
		run.tracked[mid] = nil
		run.kills = (run.kills or 0) + 1
	end
end

--- Forget an open run's adopted monsters.
function CavebotPack.clearOwners(runId)
	for mid, id in pairs(owners) do
		if id == runId then
			owners[mid] = nil
		end
	end
end
