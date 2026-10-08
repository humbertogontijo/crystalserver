-- Map-spawn lure hunts: pack tracking and session lifecycle. The instance runs
-- native copies of the world spawn XML (Game.createInstanceSpawns). Monsters keep
-- stock behaviour: they engage when they see a party member and walk back to their
-- spawn when they lose it. Engaged monsters are only tracked (pacing, metrics) while
-- Cavebot walks the route; pack tracking itself is CavebotPack (lib/idleot/cavebot).
--
-- Session fields kept for protocol / persistence: state (pending | hunting |
-- ended), alive (live instance-spawn monsters), kills. Hunts are endless unless
-- they carry a forced Fiendish (activity boost): killing it ends the hunt.

ExpeditionPack = ExpeditionPack or {}

-- monsterId -> session key (instance-spawn monsters of monster-role hunts)
local monsterOwners = {}

local FORGE_FIENDISH = 2

local geo = CombatGeo
local chebyshev = geo.chebyshev

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
	if not Instance.isPrivate(instanceId) then
		return
	end
	local session = ExpeditionManager.getSessionByInstanceId and ExpeditionManager.getSessionByInstanceId(instanceId)
	if not session or huntEnded(session) or not session.spawnsCreated or not isLureHunt(session) then
		return
	end

	monster:runHealth(0)
	monster:setTargetKeepRange(ExpeditionConfig.TARGET_KEEP_SQM)
	if session.skipOpenWorldForge ~= true and InstanceWorld and InstanceWorld.applyOpenWorldForge then
		InstanceWorld.applyOpenWorldForge(monster)
	end
	monster:registerEvent("IdleMonsterDeath")

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
	ExpeditionManager.broadcastStatus(session)

	for _, member in ipairs(ExpeditionManager.onlinePlayers(session)) do
		member:sendTextMessage(MESSAGE_EVENT_ADVANCE, "Fiendish slain - hunt complete!")
		if ActivityBoostFiendishHunt and ActivityBoostFiendishHunt.onClear then
			pcall(ActivityBoostFiendishHunt.onClear, member, session)
		end
	end

	ExpeditionManager.scheduleSessionExit(session, {
		victory = true,
		endMsg = "Expedition complete.",
	})
end

--- Boss / raid instances: keep every live instance monster homed on the anchor.
function ExpeditionPack.pullMonstersToAnchor(session)
	if not session or session.state ~= "hunting" then
		return
	end
	local instanceId = session.instance and session.instance.instanceId
	local anchor = anchorOf(session)
	local anchorPos = anchor and anchor:getPosition() or nil
	if not instanceId or not anchorPos then
		return
	end
	local dest = Position(anchorPos.x, anchorPos.y, anchorPos.z)
	for _, monster in ipairs(Game.getInstanceMonsters(instanceId)) do
		if monster:getHealth() > 0 then
			monster:setMasterPos(dest)
		end
	end
end

--- True while the session's cavebot walks its route (Cavebot.step): a lure hunt with its
--- spawns up that has not ended.
function ExpeditionPack.walksCave(session)
	return not huntEnded(session) and not session.lureFinished and isLureHunt(session) and session.spawnsCreated == true
end

--- Fights without a route (boss, raid, arena): their monsters are pulled to the anchor.
function ExpeditionPack.tickPull(session)
	if not huntEnded(session) and not session.lureFinished and not isLureHunt(session) then
		ExpeditionPack.pullMonstersToAnchor(session)
	end
end

-- ---------------------------------------------------------------------------
-- Session lifecycle
-- ---------------------------------------------------------------------------

function ExpeditionPack.spawn(session)
	if huntEnded(session) or not isLureHunt(session) then
		return
	end

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
	Cavebot.start(session)
end

--- Arena pits and boss fights own their monsters (their own "monster.died" subscribers);
--- here only lure-hunt spawns count, other deaths in a hunt just refresh engagement.
function ExpeditionPack.onMonsterDeath(creature)
	local monsterId = creature:getId()
	local key = monsterOwners[monsterId]
	monsterOwners[monsterId] = nil

	local session = key and ExpeditionManager.getSessionByKey(key) or ExpeditionManager.getSessionByInstanceId(creature:getInstanceId())
	if not session or huntEnded(session) then
		return
	end
	local counted = CavebotPack.noteKill(session, monsterId)
	local killedFiendish = session.forcedFiendishId == monsterId
	if killedFiendish then
		session.forcedFiendishId = nil
		session.fiendishKilled = true
	end
	if counted then
		session.alive = math.max(0, (session.alive or 1) - 1)
		ExpeditionManager.broadcastStatus(session)
	end
	if killedFiendish then
		ExpeditionPack.finishFiendishHunt(session)
	end
end

IdleEvents.on("monster.died", ExpeditionPack.onMonsterDeath, "ExpeditionPack")

function ExpeditionPack.clear(session)
	if not session then
		return
	end
	if session.spawnsCreated then
		ExpeditionMetrics.log(session)
	end
	local instanceId = session.instance and session.instance.instanceId
	if instanceId then
		Game.clearInstanceSpawns(instanceId)
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
