-- Map-spawn lure hunts: pack tracking and session lifecycle. The instance runs
-- native copies of the world spawn XML (Game.createInstanceSpawns). Monsters keep
-- stock behaviour: they engage when they see a party member and walk back to their
-- spawn when they lose it. Engaged monsters are only tracked (pacing, metrics) while
-- ExpeditionCavebot walks the route.
--
-- Session fields kept for protocol / persistence: state (pending | hunting |
-- ended), alive (live instance-spawn monsters), kills. Hunts are endless unless
-- they carry a forced Fiendish (activity boost): killing it ends the hunt.

ExpeditionPack = ExpeditionPack or {}

-- monsterId -> session key (instance-spawn monsters of monster-role hunts)
local monsterOwners = {}

local FORGE_FIENDISH = 2

local geo = CombatGeo
local chebyshev, nowMs = geo.chebyshev, geo.nowMs

local function huntEnded(session)
	return not session or session.state == "ended"
end

local function isLureHunt(session)
	if not session or not session.instance or not session.catalog then
		return false
	end
	if session.kind == "soulpit" or session.kind == "raid" or session.kind == "arena" then
		return false
	end
	if session.catalog.id == "soul-pit" then
		return false
	end
	return session.role ~= "arena" and session.role ~= "boss"
end

local function anchorOf(session)
	return ExpeditionConfig.getAnchorPlayer and ExpeditionConfig.getAnchorPlayer(session) or nil
end

local function memberSet(session)
	local set = {}
	for _, id in ipairs(ExpeditionManager.sessionMemberIds(session) or {}) do
		set[id] = true
	end
	return set
end

local function stopEvents(session)
	if not session then
		return
	end
	for _, field in ipairs({ "waitingEvent", "despawnEvent" }) do
		if session[field] then
			stopEvent(session[field])
			session[field] = nil
		end
	end
end

local function resetPack(session)
	session.tracked = session.tracked or {}
	session.engaged = {}
	session.releasedUntil = {}
	session.alive = 0
	for _ in pairs(session.tracked) do
		session.alive = session.alive + 1
	end
end

-- ---------------------------------------------------------------------------
-- Forced Fiendish (activity boost Fiendish Hunt): one live tracked monster carries
-- it, picked where the cave route first brings it on screen. Killing it ends the hunt.
-- ---------------------------------------------------------------------------

local function raceOf(monster)
	local mType = monster.getType and monster:getType() or nil
	return mType and mType.raceId and (tonumber(mType:raceId()) or 0) or 0
end

local function isFiendishHunt(session)
	return session ~= nil and (tonumber(session.forceFiendishCreatureId) or 0) > 0
end

--- Route order of `pos`: the step of the first route point (entry, then the lap)
--- with `pos` on its screen; past every step by the distance to the nearest point
--- when none sees it.
local function routeSightKey(route, pos)
	local step, nearest = 0, math.huge
	for _, points in ipairs({ route.entry, route.waypoints }) do
		for _, w in ipairs(points) do
			step = step + 1
			if geo.isInViewport(w, pos) then
				return step
			end
			nearest = math.min(nearest, chebyshev(w, pos))
		end
	end
	return step + nearest
end

local function makeFiendish(session, monster)
	if not monster or not monster.setMonsterForgeClassification then
		return false
	end
	monster:setMonsterForgeClassification(FORGE_FIENDISH)
	if monster.configureForgeSystem then
		monster:configureForgeSystem()
	end
	session.forcedFiendishId = monster:getId()
	return true
end

function ExpeditionPack.applyForcedFiendish(session)
	if not isFiendishHunt(session) or session.fiendishKilled or session.forcedFiendishId then
		return
	end
	local targetRace = tonumber(session.forceFiendishCreatureId)
	local route = ExpeditionConfig.caveRoute(session.catalog)
	local best, bestKey, fallback, fallbackKey = nil, math.huge, nil, math.huge
	for mid in pairs(session.tracked or {}) do
		local monster = Monster(mid)
		if monster and monster:getHealth() > 0 and (not monster.isForgeable or monster:isForgeable()) then
			local key = route and routeSightKey(route, monster:getPosition()) or 0
			if raceOf(monster) == targetRace then
				if not best or key < bestKey then
					best, bestKey = monster, key
				end
			elseif not fallback or key < fallbackKey then
				fallback, fallbackKey = monster, key
			end
		end
	end
	if not best and fallback then
		logger.warn(
			"[Expedition] Fiendish Hunt '{}': no live race {} in the hunt, forging {}",
			tostring(session.catalog and session.catalog.id),
			tostring(targetRace),
			fallback:getName()
		)
	end
	makeFiendish(session, best or fallback)
end

--- The live forced Fiendish; one that left without dying (spawn-time removal,
--- zone sweep) is re-forged on another monster.
function ExpeditionPack.forcedFiendish(session)
	local id = session and session.forcedFiendishId
	if not id then
		return nil
	end
	local monster = Monster(id)
	if monster and monster:getHealth() > 0 then
		return monster
	end
	session.forcedFiendishId = nil
	ExpeditionPack.applyForcedFiendish(session)
	return session.forcedFiendishId and Monster(session.forcedFiendishId) or nil
end

-- ---------------------------------------------------------------------------
-- Spawn hook (EventCallback monsterOnSpawn → events.lua)
-- ---------------------------------------------------------------------------

function ExpeditionPack.onInstanceMonsterSpawn(monster, _position)
	if not monster or not monster.getInstanceId then
		return
	end
	local instanceId = monster:getInstanceId()
	if instanceId < (InstanceWorld and InstanceWorld.PRIVATE_BASE or 3000000) then
		return
	end
	local session = ExpeditionManager.getSessionByInstanceId and ExpeditionManager.getSessionByInstanceId(instanceId)
	if not session or huntEnded(session) or not session.spawnsCreated or not isLureHunt(session) then
		return
	end

	monster:runHealth(0)
	monster:setTargetKeepRange(ExpeditionConfig.TARGET_KEEP_SQM)
	if ExpeditionDifficulty and ExpeditionDifficulty.flagMonster then
		ExpeditionDifficulty.flagMonster(monster, session)
	end
	if session.skipOpenWorldForge ~= true and InstanceWorld and InstanceWorld.applyOpenWorldForge then
		InstanceWorld.applyOpenWorldForge(monster)
	end
	monster:registerEvent("ExpeditionMonsterDeath")

	local mid = monster:getId()
	monsterOwners[mid] = session.key
	session.tracked = session.tracked or {}
	if not session.tracked[mid] then
		session.tracked[mid] = true
		session.alive = (session.alive or 0) + 1
	end
	if session.populated then
		ExpeditionPack.applyForcedFiendish(session)
	end
end

--- Fiendish Hunt: the forced Fiendish died — credit the activity, then leave like a
--- boss clear.
function ExpeditionPack.finishFiendishHunt(session)
	if not session or huntEnded(session) or session.lureFinished then
		return
	end
	session.lureFinished = true
	stopEvents(session)
	ExpeditionManager.broadcastStatus(session)

	for _, mid in ipairs(ExpeditionManager.sessionMemberIds(session) or {}) do
		local member = Player(mid)
		if member then
			member:sendTextMessage(MESSAGE_EVENT_ADVANCE, "Fiendish slain - hunt complete!")
			if ActivityBoostFiendishHunt and ActivityBoostFiendishHunt.onClear then
				pcall(ActivityBoostFiendishHunt.onClear, member, session)
			end
		end
	end

	ExpeditionManager.scheduleSessionExit(session, {
		victory = true,
		endMsg = "Expedition complete.",
	})
end

-- ---------------------------------------------------------------------------
-- Pack tracking (ExpeditionAI.tick, every AI_TICK_MS)
-- ---------------------------------------------------------------------------

--- Stop tracking a far / stalled monster (it is not re-tracked for a while).
local function release(session, mid)
	session.engaged[mid] = nil
	session.releasedUntil[mid] = nowMs() + 2 * ExpeditionConfig.PULL_STALL_MS
end

local function targetsMember(monster, members)
	local target = monster.getTarget and monster:getTarget() or nil
	return target ~= nil and members[target:getId()] == true
end
ExpeditionPack.targetsMember = targetsMember

--- Track a monster that took a party member as target (native aggro).
local function engage(session, mid, monster, anchorPos)
	local now = nowMs()
	session.engaged[mid] = { since = now, dist = chebyshev(monster:getPosition(), anchorPos), progressAt = now, hp = monster:getHealth() }
end

--- Chasing the party on the anchor's screen (trailing a walk counts), closing in,
--- fighting its target, or taking damage.
local function packProgress(state, monster, dist, chasing, onScreen)
	if (chasing and onScreen) or dist < (state.dist or math.huge) or dist <= 1 then
		return true
	end
	local hp = monster:getHealth()
	if hp < (state.hp or hp) then
		return true
	end
	local target = monster.getTarget and monster:getTarget() or nil
	return target ~= nil and chebyshev(monster:getPosition(), target:getPosition()) <= 1
end

--- Update engaged monsters, drop stalled / far ones, and track monsters that aggroed
--- the party. Monster movement is left to the engine.
local function tickPack(session, anchorPos, members)
	local now = nowMs()
	local releaseRadius = ExpeditionConfig.RELEASE_RADIUS
	local stallMs = ExpeditionConfig.PULL_STALL_MS

	-- Gone without a death event (despawn, teleport, instance clear); deaths are counted in onDeath.
	for mid in pairs(session.tracked) do
		if not Monster(mid) then
			session.tracked[mid] = nil
			session.engaged[mid] = nil
			session.alive = math.max(0, (session.alive or 1) - 1)
		end
	end

	for mid, state in pairs(session.engaged) do
		local monster = Monster(mid)
		if not monster or monster:getHealth() <= 0 then
			session.engaged[mid] = nil
		else
			local dist = chebyshev(monster:getPosition(), anchorPos)
			if dist > releaseRadius then
				release(session, mid)
			else
				local chasing = targetsMember(monster, members)
				if packProgress(state, monster, dist, chasing, geo.isInViewport(anchorPos, monster:getPosition())) then
					state.progressAt = now
				end
				state.dist = dist
				state.hp = monster:getHealth()
				if now - (state.progressAt or now) > stallMs then
					release(session, mid)
				end
			end
		end
	end

	-- Adopt tracked monsters that aggroed a member (released ones wait out their ban).
	for mid in pairs(session.tracked) do
		if not session.engaged[mid] and (session.releasedUntil[mid] or 0) <= now then
			local monster = Monster(mid)
			if monster and targetsMember(monster, members) then
				engage(session, mid, monster, anchorPos)
			end
		end
	end
end

--- No standable tile around `pos`: a monster there (an island spawn) never comes.
local function sealedIn(pos)
	for _, off in ipairs(geo.NEIGHBOUR_OFFSETS) do
		if geo.tileStandable(Position(pos.x + off[1], pos.y + off[2], pos.z)) then
			return false
		end
	end
	return true
end
ExpeditionPack.sealedIn = sealedIn

--- Live monsters (not summons) on the anchor's screen that some member can attack:
--- what a lure halt counts. A monster behind a wall (no clear shot from anyone) or
--- sealed on an island never arrives, so counting it would hold a halt forever.
--- Returns the count and the load: their summed health fractions (two monsters at
--- half health weigh as one).
function ExpeditionPack.monstersOnScreen(session, anchor)
	local pos = anchor:getPosition()
	local vx, vy = geo.VIEWPORT_X, geo.VIEWPORT_Y
	local members = {}
	for _, id in ipairs(ExpeditionManager.sessionMemberIds(session) or {}) do
		local member = Player(id)
		if member then
			members[#members + 1] = member
		end
	end
	if #members == 0 then
		members[1] = anchor
	end
	local n, load = 0, 0
	for _, creature in ipairs(Game.getSpectators(pos, false, false, vx, vx, vy, vy, anchor:getInstanceId())) do
		if creature:isMonster() and creature:getHealth() > 0 and not creature:getMaster() and not sealedIn(creature:getPosition()) then
			for _, member in ipairs(members) do
				if CombatAutomation.isValidAttackTarget(member, creature) then
					n = n + 1
					load = load + creature:getHealth() / math.max(1, creature:getMaxHealth())
					break
				end
			end
		end
	end
	return n, load
end

--- Boss / raid instances: keep every live instance monster homed on the anchor.
function ExpeditionPack.pullMonstersToAnchor(session)
	if not session or session.state ~= "hunting" then
		return
	end
	local instanceId = session.instance and session.instance.instanceId
	local anchor = anchorOf(session)
	local anchorPos = anchor and anchor:getPosition() or nil
	if not instanceId or not anchorPos or not Game.getMonsters then
		return
	end
	local dest = Position(anchorPos.x, anchorPos.y, anchorPos.z)
	for _, monster in ipairs(Game.getMonsters()) do
		if monster:getHealth() > 0 and monster:getInstanceId() == instanceId then
			monster:setMasterPos(dest)
		end
	end
end

function ExpeditionPack.tickLure(session)
	if huntEnded(session) or session.lureFinished then
		return
	end
	if not isLureHunt(session) then
		ExpeditionPack.pullMonstersToAnchor(session)
		return
	end
	if not session.spawnsCreated then
		return
	end
	local anchor = anchorOf(session)
	local anchorPos = anchor and anchor:getPosition() or nil
	if not anchorPos then
		return
	end
	session.tracked = session.tracked or {}
	session.engaged = session.engaged or {}
	session.releasedUntil = session.releasedUntil or {}

	local members = memberSet(session)
	tickPack(session, anchorPos, members)
	ExpeditionMetrics.tick(session, anchor, ExpeditionManager.sessionMemberIds(session))
	ExpeditionCavebot.tick(session, anchor, members)
end

-- ---------------------------------------------------------------------------
-- Session lifecycle
-- ---------------------------------------------------------------------------

function ExpeditionPack.spawn(session)
	if huntEnded(session) or not isLureHunt(session) then
		return
	end
	stopEvents(session)

	local instanceId = session.instance.instanceId
	if not session.spawnsCreated then
		session.tracked = {}
		session.alive = 0
		session.spawnsCreated = true
		session.populated = nil
		session.forcedFiendishId = nil
		session.fiendishKilled = nil
		local blocks = Game.createInstanceSpawns and Game.createInstanceSpawns(instanceId) or 0
		session.spawnBlocks = blocks
		session.populated = true
		if blocks <= 0 then
			logger.error("[Expedition] hunt '{}' has no world spawns inside its fence", tostring(session.catalog.id))
		end
		ExpeditionPack.applyForcedFiendish(session)
	end
	resetPack(session)
	ExpeditionCavebot.start(session)
end

function ExpeditionPack.onMonsterDeath(creature, corpse)
	if not creature then
		return
	end
	-- Sequential arena pits track kills in QuestArena.monsterOwners.
	if QuestArena and QuestArena.isOwnedMonster and QuestArena.isOwnedMonster(creature) then
		return
	end
	-- Boss fights own their monsters separately.
	if ExpeditionBoss and ExpeditionBoss.onMonsterDeath and ExpeditionBoss.onMonsterDeath(creature, corpse) then
		return
	end
	local monsterId = creature:getId()
	local key = monsterOwners[monsterId]
	monsterOwners[monsterId] = nil

	local session = key and ExpeditionManager.getSessionByKey(key)
	if not session and creature.getInstanceId and ExpeditionManager.getSessionByInstanceId then
		session = ExpeditionManager.getSessionByInstanceId(creature:getInstanceId())
	end
	if not session or huntEnded(session) then
		return
	end
	if session.engaged then
		session.engaged[monsterId] = nil
	end
	session.lastKillAt = nowMs()
	local killedFiendish = session.forcedFiendishId == monsterId
	if killedFiendish then
		session.forcedFiendishId = nil
		session.fiendishKilled = true
	end
	if key and session.tracked and session.tracked[monsterId] then
		session.tracked[monsterId] = nil
		session.alive = math.max(0, (session.alive or 1) - 1)
		session.kills = (session.kills or 0) + 1
		ExpeditionManager.broadcastStatus(session)
	end
	if killedFiendish then
		ExpeditionPack.finishFiendishHunt(session)
	end
end

function ExpeditionPack.clear(session)
	if not session then
		return
	end
	stopEvents(session)
	if session.spawnsCreated then
		ExpeditionMetrics.log(session)
	end
	local instanceId = session.instance and session.instance.instanceId
	if instanceId and Game.clearInstanceSpawns then
		Game.clearInstanceSpawns(instanceId)
	end
	if session.instance and session.instance.zone then
		session.instance.zone:removeMonsters()
	end
	for mid, key in pairs(monsterOwners) do
		if key == session.key then
			monsterOwners[mid] = nil
		end
	end
	session.tracked = {}
	session.engaged = {}
	session.releasedUntil = {}
	session.spawnsCreated = nil
	session.populated = nil
	session.forcedFiendishId = nil
	session.fiendishKilled = nil
	session.cave = nil
	session.lureFinished = nil
	session.metrics = nil
	session.alive = 0
end
