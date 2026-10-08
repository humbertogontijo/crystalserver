-- Pack tracking for cave walks: which monsters engaged the party (native aggro on a
-- member), whether they still come, and what the lure counts. Monster movement is
-- left to the engine. Expedition sessions track every instance-spawn monster
-- (ExpeditionPack spawn hook); open-world runs adopt only monsters that target a
-- member (CavebotPack.adoptEngaged) — a public layer's other monsters belong to other
-- players.

CavebotPack = CavebotPack or {}

local geo = CombatGeo
local chebyshev, nowMs = geo.chebyshev, geo.nowMs

-- monsterId -> open run id (adopted monsters; expedition kills go through ExpeditionPack).
-- One run owns a monster until it dies or that run drops it.
local owners = {}

local function disown(run, mid)
	if owners[mid] == run.id then
		owners[mid] = nil
	end
end

local function ownedByOther(run, mid)
	local owner = owners[mid]
	return owner ~= nil and owner ~= run.id and CavebotService ~= nil and CavebotService.getRun(owner) ~= nil
end

--- Stop tracking a far / stalled monster (it is not re-tracked for a while).
function CavebotPack.release(run, mid)
	run.engaged[mid] = nil
	run.releasedUntil[mid] = nowMs() + 2 * CavebotConfig.PULL_STALL_MS
end

function CavebotPack.targetsMember(monster, members)
	local target = monster:getTarget()
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

--- No standable tile around `pos` in `instanceId`: a monster there (an island spawn)
--- never comes.
function CavebotPack.sealedIn(pos, instanceId)
	for _, off in ipairs(geo.NEIGHBOUR_OFFSETS) do
		if geo.tileStandable(Position(pos.x + off[1], pos.y + off[2], pos.z), instanceId) then
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
				if mpos.z == z and tpos.z == z and inSight and not sealedIn(mpos, monster:getInstanceId()) then
					out[#out + 1] = { monster = monster, state = state, target = target }
				end
			end
		end
	end
	return out
end

--- One tick's view of the pack, shared by adoptEngaged, lureCount and the leash: `aggro`
--- = live monsters (not summons) targeting a member on the anchor's screen (on every
--- member's screen with `allMembers`), each once; `chasers` (CavebotPack.chasers with the
--- stuck ones) is filled in by Cavebot.step once the pack is tracked.
function CavebotPack.snapshot(run, anchor, members, allMembers)
	local memberIds = {}
	for id in pairs(members) do
		memberIds[#memberIds + 1] = id
	end
	local aggro, seen = {}, {}
	local function scan(viewer)
		local found = Game.scanMonsters(viewer:getPosition(), { instance = viewer:getInstanceId(), noSummons = true, targeting = memberIds })
		for _, monster in ipairs(found) do
			local mid = monster:getId()
			if not seen[mid] then
				seen[mid] = true
				aggro[#aggro + 1] = monster
			end
		end
	end
	scan(anchor)
	if allMembers then
		for id in pairs(members) do
			local member = id ~= anchor:getId() and Player(id)
			if member then
				scan(member)
			end
		end
	end
	return { now = nowMs(), aggro = aggro, chasers = {} }
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
--- a member and that some member can attack, plus every chaser (`pack.chasers`, not
--- given up on) on a member off that screen but on that member's screen, each once. An
--- idle monster or one on another player never follows the walk; one behind a wall (no
--- clear shot from anyone) or sealed on an island never arrives, so counting them would
--- hold a halt forever. `pack`: CavebotPack.snapshot; `members`: set of member ids.
--- Returns the count and the load: their summed health fractions (two monsters at half
--- health weigh as one).
function CavebotPack.lureCount(pack, anchor, members)
	local pos = anchor:getPosition()
	local players = memberPlayers(members, anchor)
	local n, load, counted = 0, 0, {}
	local function count(monster)
		counted[monster:getId()] = true
		n = n + 1
		load = load + monster:getHealth() / math.max(1, monster:getMaxHealth())
	end
	for _, creature in ipairs(pack.aggro) do
		local mpos = creature:getPosition()
		if geo.isInViewport(pos, mpos) and not sealedIn(mpos, creature:getInstanceId()) then
			for _, member in ipairs(players) do
				if CombatAutomation.isValidAttackTarget(member, creature) then
					count(creature)
					break
				end
			end
		end
	end
	for _, chaser in ipairs(pack.chasers) do
		if not counted[chaser.monster:getId()] and (chaser.state.lagStuckUntil or 0) <= pack.now then
			count(chaser.monster)
		end
	end
	return n, load
end

-- ---------------------------------------------------------------------------
-- Open-world runs: aggro-based tracking
-- ---------------------------------------------------------------------------

--- Track monsters (not summons) on a member's screen that target a member (`pack.aggro`,
--- a snapshot over every member); drop tracked monsters that are neither engaged nor on
--- the party any more.
function CavebotPack.adoptEngaged(run, members, pack)
	local seen = {}
	for _, creature in ipairs(pack.aggro) do
		local mid = creature:getId()
		if not ownedByOther(run, mid) then
			seen[mid] = true
			if not run.tracked[mid] then
				run.tracked[mid] = true
				owners[mid] = run.id
				creature:registerEvent("IdleMonsterDeath")
			end
		end
	end
	for mid in pairs(run.tracked) do
		if not seen[mid] and not run.engaged[mid] then
			run.tracked[mid] = nil
			disown(run, mid)
		end
	end
end

--- Kill bookkeeping shared by open runs and expedition sessions; true when `mid`
--- was one of the run's tracked monsters.
function CavebotPack.noteKill(run, mid)
	if run.engaged then
		run.engaged[mid] = nil
	end
	run.lastKillAt = nowMs()
	if run.tracked and run.tracked[mid] then
		run.tracked[mid] = nil
		run.kills = (run.kills or 0) + 1
		return true
	end
	return false
end

--- An adopted monster died.
function CavebotPack.onMonsterDeath(creature)
	local mid = creature and creature:getId()
	local runId = mid and owners[mid]
	if not runId then
		return
	end
	owners[mid] = nil
	local run = CavebotService.getRun(runId)
	if not run then
		return
	end
	CavebotPack.noteKill(run, mid)
end

IdleEvents.on("monster.died", CavebotPack.onMonsterDeath, "CavebotPack")

--- A tracked monster left the map without dying (despawn, teleport, instance clear);
--- deaths reach noteKill through "monster.died" first.
function CavebotPack.onMonsterRemoved(monster)
	local mid = monster:getId()
	local run
	if owners[mid] then
		run = CavebotService.getRun(owners[mid])
	else
		local session = ExpeditionManager.getSessionByInstanceId(monster:getInstanceId())
		run = session and session.cave and session or nil
	end
	if not (run and run.tracked and run.tracked[mid]) then
		return
	end
	run.tracked[mid] = nil
	if run.engaged then
		run.engaged[mid] = nil
	end
	run.alive = math.max(0, (run.alive or 1) - 1)
	disown(run, mid)
end

IdleEvents.on("monster.removed", CavebotPack.onMonsterRemoved, "CavebotPack")

--- Forget an open run's adopted monsters.
function CavebotPack.clearOwners(runId)
	for mid, id in pairs(owners) do
		if id == runId then
			owners[mid] = nil
		end
	end
end
