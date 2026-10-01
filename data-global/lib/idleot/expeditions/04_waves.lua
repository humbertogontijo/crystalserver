-- Map-spawn lure hunts. The instance runs native copies of the world spawn XML
-- (Game.createInstanceSpawns); the anchor walks hold to hold along the catalog
-- route and pulls monsters inside the pull ring onto itself while everyone
-- attacks, then fights the gathered pack at each hold.
--
-- Session fields kept for protocol / persistence: state (relocating | hunting |
-- waiting), wave (holds visited), alive (live instance-spawn monsters), kills.

ExpeditionWaves = ExpeditionWaves or {}

-- monsterId -> session key (instance-spawn monsters of monster-role hunts)
local monsterOwners = {}
ExpeditionWaves.monsterOwners = monsterOwners

local FORGE_FIENDISH = 2

local function huntEnded(session)
	return not session or session.state == "ended"
end

local function nowMs()
	return os.mtime and os.mtime() or (os.time() * 1000)
end

local function cfg(name, default)
	local v = tonumber(ExpeditionConfig and ExpeditionConfig[name])
	if v == nil then
		return default
	end
	return v
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

local function waveLimitReached(session)
	local maxWaves = session and tonumber(session.maxWaves)
	if not maxWaves or maxWaves <= 0 then
		return false
	end
	return (tonumber(session.wave) or 0) >= maxWaves
end

local function chebyshev(a, b)
	if not a or not b or a.z ~= b.z then
		return math.huge
	end
	return math.max(math.abs(a.x - b.x), math.abs(a.y - b.y))
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

local function lureCount(session)
	local n = math.floor(tonumber(session and session.lure) or 0)
	if n < 1 then
		n = math.floor(tonumber(ExpeditionConfig.sessionHoldLure(session)) or 0)
	end
	return math.max(1, n)
end

local function stopEvents(session)
	if not session then
		return
	end
	for _, field in ipairs({ "waitingEvent", "relocateEvent", "relocateTimeoutEvent", "relocateReadyEvent", "relocateWalkEvent", "despawnEvent" }) do
		if session[field] then
			stopEvent(session[field])
			session[field] = nil
		end
	end
end

local function resetLure(session)
	session.tracked = session.tracked or {}
	session.engaged = {}
	session.releasedUntil = {}
	session.lureHalt = nil
	session.alive = 0
	for _ in pairs(session.tracked) do
		session.alive = session.alive + 1
	end
end

-- ---------------------------------------------------------------------------
-- Forced Fiendish (activity boost): one live tracked monster carries it.
-- ---------------------------------------------------------------------------

local function raceOf(monster)
	local mType = monster.getType and monster:getType() or nil
	return mType and mType.raceId and (tonumber(mType:raceId()) or 0) or 0
end

local function makeFiendish(session, monster)
	if not monster or not monster.setMonsterForgeClassification then
		return false
	end
	if monster.isForgeable and not monster:isForgeable() then
		return false
	end
	monster:setMonsterForgeClassification(FORGE_FIENDISH)
	if monster.configureForgeSystem then
		monster:configureForgeSystem()
	end
	session.forcedFiendishId = monster:getId()
	return true
end

function ExpeditionWaves.applyForcedFiendish(session)
	if not session or session.forcedFiendishId then
		return
	end
	local targetRace = tonumber(session.forceFiendishCreatureId)
	if not targetRace or targetRace <= 0 then
		return
	end
	local fallback = nil
	for mid in pairs(session.tracked or {}) do
		local monster = Monster(mid)
		if monster and monster:getHealth() > 0 then
			if raceOf(monster) == targetRace and makeFiendish(session, monster) then
				return
			end
			fallback = fallback or monster
		end
	end
	if fallback then
		makeFiendish(session, fallback)
	end
end

-- ---------------------------------------------------------------------------
-- Spawn hook (EventCallback monsterOnSpawn → events.lua)
-- ---------------------------------------------------------------------------

function ExpeditionWaves.onInstanceMonsterSpawn(monster, _position)
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
		ExpeditionWaves.applyForcedFiendish(session)
	end
end

--- Extra monsters that belong to the fight (echo raids): pinned to the anchor, never released.
function ExpeditionWaves.adoptMonster(session, monster)
	if not session or not monster or huntEnded(session) then
		return
	end
	session.engaged = session.engaged or {}
	session.engaged[monster:getId()] = { since = nowMs(), pinned = true }
	local anchor = anchorOf(session)
	local home = anchor and anchor:getPosition() or session.holdPos
	if home and monster.setMasterPos then
		monster:setMasterPos(Position(home.x, home.y, home.z))
	end
end

-- ---------------------------------------------------------------------------
-- Holds and route
-- ---------------------------------------------------------------------------

--- Next point the anchor walks to: pending route waypoint of the incoming leg, else the hold.
function ExpeditionWaves.walkTarget(session)
	if not session or not session.holdPos then
		return nil
	end
	local route = session.route
	local idx = session.routeIdx or 1
	if type(route) == "table" and idx <= #route then
		local wp = route[idx]
		return Position(wp.x, wp.y, wp.z)
	end
	return session.holdPos
end

local function pullRing(session)
	return tonumber(session.catalog and session.catalog.pullRing) or cfg("PULL_RING", 8)
end

local function pullSteps(session)
	return tonumber(session.catalog and session.catalog.pullSteps) or cfg("PULL_STEPS", 8)
end

local function anchorArrived(session, anchorPos)
	local hold = session.holdPos
	if not hold then
		return true
	end
	return chebyshev(anchorPos, hold) <= cfg("HOLD_ARRIVE_RADIUS", 1)
end
ExpeditionWaves.anchorArrived = function(session)
	local anchor = anchorOf(session)
	return anchor ~= nil and anchorArrived(session, anchor:getPosition())
end

local function beginRelocate(session)
	session.state = "relocating"
	local hold = ExpeditionConfig.holdForWave(session.catalog, math.max(1, tonumber(session.wave) or 1))
	session.route = hold and hold.route or nil
	session.routeIdx = 1
	session._relocateProgress = { dist = math.huge, at = nowMs() }
	if ExpeditionAI and ExpeditionAI.startRelocateWalk then
		ExpeditionAI.startRelocateWalk(session)
	end
	ExpeditionManager.broadcastStatus(session)
end

--- Finite hunt: maxWaves holds cleared — credit hooks, then leave like a boss clear.
function ExpeditionWaves.finishWaveLimitedHunt(session)
	if not session or huntEnded(session) or session.lureFinished then
		return
	end
	session.lureFinished = true
	session.state = "waiting"
	stopEvents(session)
	ExpeditionManager.broadcastStatus(session)

	for _, mid in ipairs(ExpeditionManager.sessionMemberIds(session) or {}) do
		local member = Player(mid)
		if member then
			member:sendTextMessage(MESSAGE_EVENT_ADVANCE, "Hunt complete!")
			if ActivityBoostFiendishHunt and ActivityBoostFiendishHunt.onClear then
				pcall(ActivityBoostFiendishHunt.onClear, member, session)
			end
			if type(session.onWaveLimitReached) == "function" then
				pcall(session.onWaveLimitReached, member, session)
			end
		end
	end

	ExpeditionManager.scheduleSessionExit(session, {
		victory = true,
		endMsg = "Expedition complete.",
	})
end

local function nextHold(session)
	session.packFought = nil
	if waveLimitReached(session) then
		ExpeditionWaves.finishWaveLimitedHunt(session)
		return
	end
	local shouldWalk = ExpeditionConfig.advanceWave(session)
	if shouldWalk then
		beginRelocate(session)
	else
		-- Single-hold hunt: stay and keep pulling what respawns.
		session.state = "waiting"
		ExpeditionManager.broadcastStatus(session)
	end
end

--- Relocate walk reached the hold (called from ExpeditionAI.startRelocateWalk).
function ExpeditionWaves.onRelocatePartySettled(session)
	if not session or session.state ~= "relocating" then
		return
	end
	if session.relocateWalkEvent then
		stopEvent(session.relocateWalkEvent)
		session.relocateWalkEvent = nil
	end
	session.state = "hunting"
	session._relocateProgress = nil
	ExpeditionManager.broadcastStatus(session)
end

-- ---------------------------------------------------------------------------
-- Lure tick (ExpeditionAI.tick, every AI_TICK_MS)
-- ---------------------------------------------------------------------------

local function engagedCount(session)
	local n = 0
	for _ in pairs(session.engaged or {}) do
		n = n + 1
	end
	return n
end

local function release(session, mid, monster)
	session.engaged[mid] = nil
	session.releasedUntil[mid] = nowMs() + 2 * cfg("PULL_STALL_MS", 8000)
	if monster and monster.setMasterPos and monster.getSpawnPosition then
		local home = monster:getSpawnPosition()
		if home then
			monster:setMasterPos(home)
		end
	end
end

local function targetsMember(monster, members)
	local target = monster.getTarget and monster:getTarget() or nil
	return target ~= nil and members[target:getId()] == true
end

local function pullPath(session, monster, anchorPos)
	local path = monster:getPathTo(anchorPos, 0, 1, true, false, pullRing(session) + 1)
	return type(path) == "table" and #path <= pullSteps(session)
end

--- Engage one monster: home on the anchor so C++ walk-back leads it into the party.
local function engage(session, mid, monster, anchor, anchorPos)
	session.engaged[mid] = { since = nowMs(), dist = chebyshev(monster:getPosition(), anchorPos), progressAt = nowMs() }
	monster:setMasterPos(Position(anchorPos.x, anchorPos.y, anchorPos.z))
	if monster.selectTarget and anchor then
		monster:selectTarget(anchor)
	end
end

--- Keep engaged monsters homed on the anchor, drop stalled / far ones, and adopt
--- monsters already fighting the party.
local function tickPack(session, anchor, anchorPos)
	local now = nowMs()
	local members = memberSet(session)
	local releaseRadius = cfg("RELEASE_RADIUS", 18)
	local stallMs = cfg("PULL_STALL_MS", 8000)
	local home = Position(anchorPos.x, anchorPos.y, anchorPos.z)

	for mid in pairs(session.tracked) do
		local monster = Monster(mid)
		if not monster or monster:getHealth() <= 0 then
			session.tracked[mid] = nil
			session.engaged[mid] = nil
		end
	end

	for mid, state in pairs(session.engaged) do
		local monster = Monster(mid)
		if not monster or monster:getHealth() <= 0 then
			session.engaged[mid] = nil
		else
			local dist = chebyshev(monster:getPosition(), anchorPos)
			if state.pinned then
				monster:setMasterPos(home)
			elseif dist > releaseRadius then
				release(session, mid, monster)
			else
				if dist < (state.dist or math.huge) or dist <= 1 or targetsMember(monster, members) then
					state.progressAt = now
				end
				state.dist = dist
				if now - (state.progressAt or now) > stallMs then
					release(session, mid, monster)
				else
					monster:setMasterPos(home)
				end
			end
		end
	end

	-- Adopt tracked monsters that already fight the party (aggro from a member).
	for mid in pairs(session.tracked) do
		if not session.engaged[mid] then
			local monster = Monster(mid)
			if monster and targetsMember(monster, members) then
				engage(session, mid, monster, anchor, anchorPos)
			end
		end
	end
end

--- Pull the nearest idle monsters in the ring (path ≤ PULL_STEPS) up to the hold's lure.
local function pullPack(session, anchor, anchorPos)
	local now = nowMs()
	local lure = lureCount(session)
	local count = engagedCount(session)
	if count >= lure then
		return
	end
	local ring = pullRing(session)
	local candidates = {}
	for mid in pairs(session.tracked) do
		if not session.engaged[mid] and (session.releasedUntil[mid] or 0) <= now then
			local monster = Monster(mid)
			local dist = monster and chebyshev(monster:getPosition(), anchorPos) or math.huge
			if dist <= ring then
				candidates[#candidates + 1] = { mid = mid, monster = monster, dist = dist }
			end
		end
	end
	table.sort(candidates, function(a, b)
		return a.dist < b.dist
	end)
	local budget = cfg("PULL_PATHS_PER_TICK", 6)
	for _, c in ipairs(candidates) do
		if count >= lure or budget <= 0 then
			break
		end
		budget = budget - 1
		if pullPath(session, c.monster, anchorPos) then
			engage(session, c.mid, c.monster, anchor, anchorPos)
			count = count + 1
		end
	end
end

--- Engaged monsters the anchor can see and attack: what a player waits on at a hold.
--- The rest keep following the anchor (homed on it) to the next hold.
local function visibleEngagedCount(session, anchor)
	local anchorPos = anchor:getPosition()
	local n = 0
	for mid in pairs(session.engaged) do
		local monster = Monster(mid)
		if
			monster
			and CombatAutomationMovement.isInViewport(anchorPos, monster:getPosition())
			and CombatAutomation.isValidAttackTarget(anchor, monster)
		then
			n = n + 1
		end
	end
	return n
end

--- Walking a leg the anchor lures until the pack reaches lure × LURE_STOP_FACTOR, then
--- stops and fights it there; it walks on once nothing attackable is in view.
local function updateLureHalt(session, anchor)
	local cap = lureCount(session) * cfg("LURE_STOP_FACTOR", 1)
	local count = engagedCount(session)
	if not session.lureHalt then
		session.lureHalt = count >= cap or nil
	elseif count < cap and visibleEngagedCount(session, anchor) == 0 then
		session.lureHalt = nil
	end
end

local function tickRelocate(session, anchorPos, engaged)
	if anchorArrived(session, anchorPos) then
		ExpeditionWaves.onRelocatePartySettled(session)
		return
	end
	local target = ExpeditionWaves.walkTarget(session)
	if target and target ~= session.holdPos then
		local anchor = anchorOf(session)
		local blocked = anchor
			and CombatAutomationMovement
			and CombatAutomationMovement.walkBlocked
			and CombatAutomationMovement.walkBlocked(anchor, target)
		if blocked or chebyshev(anchorPos, target) <= 1 then
			session.routeIdx = (session.routeIdx or 1) + 1
			session._relocateProgress = { dist = math.huge, at = nowMs() }
			return
		end
	end
	if session.lureHalt or engaged > 0 then
		-- Fighting on the way is progress; stalls only count while walking alone.
		local progress = session._relocateProgress
		if progress then
			progress.at = nowMs()
		end
		if session.lureHalt then
			return
		end
	end
	local progress = session._relocateProgress or { dist = math.huge, at = nowMs() }
	session._relocateProgress = progress
	local dist = chebyshev(anchorPos, target or session.holdPos)
	if dist < progress.dist then
		progress.dist = dist
		progress.at = nowMs()
		return
	end
	if nowMs() - progress.at > cfg("RELOCATE_STALL_MS", 12000) then
		local route = session.route
		if type(route) == "table" and (session.routeIdx or 1) <= #route then
			-- Unreachable waypoint: head straight for the hold.
			session.routeIdx = #route + 1
			session._relocateProgress = { dist = math.huge, at = nowMs() }
			return
		end
		logger.warn(
			"[Expedition] relocate stalled toward hold {}; skipping to the next hold",
			session.holdPos and string.format("%d,%d,%d", session.holdPos.x, session.holdPos.y, session.holdPos.z) or "?"
		)
		nextHold(session)
	end
end

--- Boss / raid instances: keep every live instance monster homed on the anchor.
function ExpeditionWaves.pullMonstersToAnchor(session)
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

function ExpeditionWaves.tickLure(session)
	if huntEnded(session) or session.lureFinished then
		return
	end
	if not isLureHunt(session) then
		ExpeditionWaves.pullMonstersToAnchor(session)
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

	tickPack(session, anchor, anchorPos)

	if session.state == "relocating" then
		updateLureHalt(session, anchor)
		if not session.lureHalt then
			pullPack(session, anchor, anchorPos)
		end
		tickRelocate(session, anchorPos, engagedCount(session))
		return
	end
	session.lureHalt = nil

	-- At the hold: one pull, never a top-up mid-fight (respawns wait for the next lap);
	-- move on once nothing attackable is in view.
	-- A stationary hunt stays put, counts a hold clear per pack and pulls again.
	local previous = session.state
	if not session.packFought then
		pullPack(session, anchor, anchorPos)
	end
	local visible = visibleEngagedCount(session, anchor)
	session.state = visible > 0 and "hunting" or "waiting"
	if visible > 0 then
		session.packFought = true
	elseif ExpeditionConfig.canRelocateHolds(session.catalog) or session.packFought then
		nextHold(session)
		return
	end
	if previous ~= session.state then
		ExpeditionManager.broadcastStatus(session)
	end
end

-- ---------------------------------------------------------------------------
-- Session lifecycle
-- ---------------------------------------------------------------------------

function ExpeditionWaves.spawn(session)
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
		local blocks = Game.createInstanceSpawns and Game.createInstanceSpawns(instanceId) or 0
		session.spawnBlocks = blocks
		session.populated = true
		if blocks <= 0 then
			logger.error("[Expedition] hunt '{}' has no world spawns inside its fence", tostring(session.catalog.id))
		end
		ExpeditionWaves.applyForcedFiendish(session)
	end
	resetLure(session)

	-- Resume keeps session.wave; a fresh hunt starts at hold 1.
	if (tonumber(session.wave) or 0) < 1 then
		ExpeditionConfig.advanceWave(session)
	else
		ExpeditionConfig.syncHoldFromWave(session)
	end
	session.waveLure = lureCount(session)
	beginRelocate(session)
end

function ExpeditionWaves.onMonsterDeath(creature, corpse)
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
	if session.forcedFiendishId == monsterId then
		session.forcedFiendishId = nil
	end
	if key and session.tracked and session.tracked[monsterId] then
		session.tracked[monsterId] = nil
		session.alive = math.max(0, (session.alive or 1) - 1)
		session.kills = (session.kills or 0) + 1
		ExpeditionManager.broadcastStatus(session)
	end
end

function ExpeditionWaves.clear(session)
	if not session then
		return
	end
	stopEvents(session)
	if session.spawnsCreated and session.startedAt then
		local minutes = math.max(1, os.time() - session.startedAt) / 60
		logger.info(
			"[Expedition] lure hunt '{}' ended: {} kills, {} holds, {} blocks, {} kills/min",
			tostring(session.catalog and session.catalog.id),
			session.kills or 0,
			session.wave or 0,
			session.spawnBlocks or 0,
			string.format("%.1f", (session.kills or 0) / minutes)
		)
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
	session.lureHalt = nil
	session.lureFinished = nil
	session.packFought = nil
	session.alive = 0
end
