ExpeditionBoss = ExpeditionBoss or {}

-- monsterId -> session key (boss fights share the instance death event with the lure pack)
local bossOwners = {}

-- Kill-gates only: immunity / cancel-death. THINK heals & summons stay (boss essence).
local KILL_GATE_EVENT_TYPES = {
	CREATURE_EVENT_HEALTHCHANGE,
	CREATURE_EVENT_PREPAREDEATH,
}

local function preSpawnDurationMs()
	local flashes = ExpeditionConfig.PRE_SPAWN_FLASHES or 3
	local interval = ExpeditionConfig.PRE_SPAWN_INTERVAL_MS or 1400
	return flashes * interval, flashes, interval
end

local function clearDespawn(session)
	ExpeditionManager.scope(session):cancel("bossDespawn")
	session.bossEndsAt = nil
	session.bossTimeLimitSec = nil
end

local function retrySpawn(session)
	session.state = "waiting"
	ExpeditionManager.scope(session):timer("bossSpawn", 1500, function()
		ExpeditionBoss.spawn(session)
	end)
end

--- HEALTHCHANGE kill-gates only (phase transforms must stay registered); boss mechanics
--- add the immunity events they play (ExpeditionBossMechanics.register opts.immunity).
--- tentuglysHeadPhase: CIP tentacle teleport/arena (absolute multi-floor).
local KILL_GATE_HEALTHCHANGE = {
	["monster.invulnerable"] = true,
	["tentuglysHeadPhase"] = true,
}

local function isKillGateHealthChange(name)
	return KILL_GATE_HEALTHCHANGE[name] or ExpeditionBossMechanics.isImmunityEvent(name)
end

--- Kill-gate events of `monster` (opts.keepPrepareDeath: lever arenas keep PREPAREDEATH,
--- their phase transforms run there).
local function killGates(monster, opts)
	local gates = {}
	for i = 1, #KILL_GATE_EVENT_TYPES do
		local eventType = KILL_GATE_EVENT_TYPES[i]
		local skip = eventType == nil or (eventType == CREATURE_EVENT_PREPAREDEATH and opts and opts.keepPrepareDeath)
		local events = not skip and monster:getEvents(eventType) or nil
		if type(events) == "table" then
			for j = 1, #events do
				local name = events[j]
				if name and name ~= "" and (eventType ~= CREATURE_EVENT_HEALTHCHANGE or isKillGateHealthChange(name)) then
					gates[#gates + 1] = name
				end
			end
		end
	end
	return gates
end

--- Neutralize scripts that block HP from reaching 0. Keeps THINK (heals/summons).
--- Always preserves non-kill-gate HEALTHCHANGE (e.g. UrmahlulluChanges phase transforms).
function ExpeditionBoss.ensureKillable(monster, opts)
	if not monster then
		return false
	end
	for _, name in ipairs(killGates(monster, opts)) do
		monster:unregisterEvent(name)
	end
	pcall(function()
		monster:immune(false)
	end)
	return true
end

--- True when the boss still has kill-gate scripts attached.
function ExpeditionBoss.hasKillGates(monster, opts)
	return monster ~= nil and #killGates(monster, opts) > 0
end

local function sessionLever(session)
	return session and session.catalog and ExpeditionConfig.bossLever(session.catalog) or nil
end

--- Lever whose fight is run by a stock Encounter script (stages, adds, the boss spawn):
--- the expedition runs an instance copy of that script instead of spawning the boss.
local function encounterDriven(lever)
	return lever and lever.encounter and EncounterInstances and EncounterInstances.has(lever.encounter) or false
end

--- The fight plays its own immunity mechanic: a boss mechanic, or the stock encounter's stages.
local function playsMechanic(lever)
	return lever ~= nil and (encounterDriven(lever) or ExpeditionBossMechanics.handles(lever))
end

--- Bosses whose mechanic is played keep their immunity; it is stripped when the boss stays
--- immune past BOSS_MECHANIC_STALL_SEC (mechanic stuck). Other bosses lose it right away.
function ExpeditionBoss.ensureKillableSession(session)
	local boss = ExpeditionBoss.getBoss(session)
	local lever = sessionLever(session)
	local opts = { keepPrepareDeath = lever ~= nil }
	if not boss or not ExpeditionBoss.hasKillGates(boss, opts) then
		if session then
			session.killGateSince = nil
		end
		return false
	end
	if playsMechanic(lever) then
		local now = os.time()
		session.killGateSince = session.killGateSince or now
		local stallSec = ExpeditionConfig.BOSS_MECHANIC_STALL_SEC
		if now - session.killGateSince < stallSec then
			return false
		end
		logger.warn(
			"[Expedition] {} stayed immune {}s in {} ({}); stripping its immunity",
			boss:getName(),
			stallSec,
			session.instance and session.instance.instanceId or "?",
			table.concat(killGates(boss, opts), ",")
		)
		session.killGateSince = nil
	end
	return ExpeditionBoss.ensureKillable(boss, opts)
end

local function stopEncounterCopy(session, opts)
	local lever = sessionLever(session)
	if encounterDriven(lever) and session.instance and EncounterInstances then
		EncounterInstances.stop(session.instance.instanceId, lever.encounter, opts)
	end
end

--- Phase transforms remove+recreate the monster; re-bind ownership to the new form.
--- Lever fights run in the lever's own arena (kill-gates handled by ensureKillableSession)
--- and forms fought together keep their owner entries.
function ExpeditionBoss.bindBoss(session, monster)
	if not session or not monster then
		return false
	end
	local mid = monster:getId()
	local lever = sessionLever(session)
	if not lever then
		-- Drop stale owner entries for this session (previous phase creature ids).
		for id, ownerKey in pairs(bossOwners) do
			if ownerKey == session.key and id ~= mid then
				bossOwners[id] = nil
			end
		end
	end
	bossOwners[mid] = session.key
	session.bossCreatureId = mid
	session.alive = 1
	session.phaseTransform = nil
	monster:registerEvent("IdleMonsterDeath")
	if not lever then
		ExpeditionBoss.ensureKillable(monster)
	end
	IdleEvents.emit("boss.bound", session, monster)
	return true
end

--- BossLever:spawnForm hook: later forms of a chained lever fight join the session
--- running that lever in the form's instance.
local function onLeverFormSpawned(monster, lever)
	if not monster or not monster.getInstanceId or not ExpeditionManager then
		return
	end
	local instanceId = monster:getInstanceId()
	if Instance.isWorld(instanceId) then
		return
	end
	local session = ExpeditionManager.getSessionByInstanceId(instanceId)
	if session and session.state == "hunting" and sessionLever(session) == lever then
		ExpeditionBoss.bindBoss(session, monster)
	end
end

-- Product libs load before data/libs (BossLever), so the hook installs on first use.
local function ensureLeverHook()
	if BossLever and BossLever.addPhaseHook and not ExpeditionBoss.leverHookAdded then
		ExpeditionBoss.leverHookAdded = true
		BossLever.addPhaseHook(function(monster, lever)
			onLeverFormSpawned(monster, lever)
		end)
	end
end
ensureLeverHook()

function ExpeditionBoss.rebindBossIfNeeded(session)
	if not session or session.state ~= "hunting" then
		return nil
	end
	local instanceId = session.instance and session.instance.instanceId
	if not instanceId then
		return nil
	end
	if session.bossCreatureId then
		local current = Monster(session.bossCreatureId)
		if current and current:getHealth() > 0 then
			return current
		end
		session.bossCreatureId = nil
	end
	local wantRace = session.bossRaceId or (session.catalog and session.catalog.creatureId)
	if (not wantRace or wantRace <= 0) and session.catalog and type(session.catalog.creatureIds) == "table" then
		wantRace = session.catalog.creatureIds[1]
	end
	for _, monster in ipairs(Game.getInstanceMonsters(instanceId)) do
		if monster:getHealth() > 0 then
			local mid = monster:getId()
			if bossOwners[mid] == session.key then
				ExpeditionBoss.bindBoss(session, monster)
				return monster
			end
			-- Multi-phase forms share bossRaceId (e.g. Urmahlullu); rebind after remove()+createMonster.
			if wantRace and wantRace > 0 and ExpeditionConfig and ExpeditionConfig.creatureIdFromMonster then
				local raceId = ExpeditionConfig.creatureIdFromMonster(monster)
				if raceId == wantRace then
					ExpeditionBoss.bindBoss(session, monster)
					return monster
				end
			end
		end
	end
	return nil
end

local function bossSpawnPos(session)
	local center = nil
	local anchor = ExpeditionConfig.getAnchorPlayer and ExpeditionConfig.getAnchorPlayer(session)
	if anchor then
		center = anchor:getPosition()
	end
	if not center then
		center = session.instance and session.instance.entry
	end
	if not center then
		return nil
	end
	-- Place boss a few tiles from the anchor so the party can approach.
	-- Reserved set kept for API parity with multi-spawn expedition planners.
	local reserved = {}
	local pos = ExpeditionInstance.randomAttackRangeWalkable(session.instance, center, 3, reserved)
	return pos or ExpeditionInstance.randomWalkable(session.instance, nil, reserved)
end

--- Drop the arena's remaining monsters (crew, adds, respawns) once the fight is over;
--- player summons stay. Deferred so the dying boss finishes its own death scripts.
local function clearArena(session)
	local instanceId = session.instance and session.instance.instanceId
	if Instance.isWorld(instanceId) then
		return
	end
	addEvent(function()
		Game.clearInstanceSpawns(instanceId)
		for _, monster in ipairs(Game.getInstanceMonsters(instanceId)) do
			if monster:getHealth() > 0 then
				local master = monster:getMaster()
				if not (master and master:isPlayer()) then
					monster:remove()
				end
			end
		end
	end, SCHEDULER_MIN_TICKS or 50)
end

--- Shared overtime / victory end: loot delay then leave (or teardown if everyone offline).
local function finishBoss(session, opts)
	opts = opts or {}
	local victory = opts.victory == true
	local lever = sessionLever(session)

	clearDespawn(session)
	stopEncounterCopy(session, { keepCallbacks = true })
	ExpeditionBossMechanics.stop(session)
	clearArena(session)
	for mid, ownerKey in pairs(bossOwners) do
		if ownerKey == session.key then
			bossOwners[mid] = nil
		end
	end
	session.alive = 0
	session.bossCreatureId = nil
	session.state = "waiting"
	if lever and session.instance then
		lever:clearEncounter(session.instance.instanceId)
	end
	ExpeditionManager.broadcastStatus(session)

	local midMsg = victory and "Boss defeated! Looting..." or "Time expired! Expedition failed."
	local endMsg = victory and "Expedition complete." or "Expedition failed."

	for _, member in ipairs(ExpeditionManager.onlinePlayers(session)) do
		member:setFollowCreature(nil)
		member:setTarget(nil)
		member:sendTextMessage(MESSAGE_EVENT_ADVANCE, midMsg)
		ExpeditionConfig.clearBossAttempt(member)
		if victory and lever and session.bossDifficulty and BossDifficulty then
			BossDifficulty.unlock(member, lever, session.bossDifficulty)
		end
		if victory and ActivityBoostActivities and ActivityBoostActivities.onBossExpeditionVictory then
			pcall(ActivityBoostActivities.onBossExpeditionVictory, member, session)
		end
	end

	ExpeditionManager.scope(session):cancel("bossSpawn")

	ExpeditionManager.scheduleSessionExit(session, {
		victory = victory,
		endMsg = endMsg,
	})
end

--- Lever-style timeToDefeat: despawn boss and fail the expedition (overtime).
function ExpeditionBoss.scheduleDespawn(session)
	if not session then
		return
	end
	clearDespawn(session)
	local key = session.key
	local sec = ExpeditionConfig.bossTimeToDefeatSec and ExpeditionConfig.bossTimeToDefeatSec(sessionLever(session))
		or ExpeditionConfig.BOSS_TIME_TO_DEFEAT_SEC
		or (20 * 60)
	sec = math.floor(sec)
	session.bossTimeLimitSec = sec
	session.bossEndsAt = os.time() + sec
	ExpeditionManager.scope(session):timer("bossDespawn", sec * 1000, function()
		if session.state ~= "hunting" then
			return
		end
		local bossId = session.bossCreatureId
		if bossId then
			bossOwners[bossId] = nil
			local monster = Monster(bossId)
			if monster then
				monster:remove()
			end
		end
		for mid, ownerKey in pairs(bossOwners) do
			if ownerKey == key then
				bossOwners[mid] = nil
				local monster = Monster(mid)
				if monster then
					monster:remove()
				end
			end
		end
		finishBoss(session, { victory = false })
	end)
end

local function isLeverBossMonster(monster, lever)
	local name = monster:getName():lower()
	if name == lever.name or lever:isFinalBoss(name) then
		return true
	end
	local mType = monster:getType()
	return mType and mType.isRewardBoss and mType:isRewardBoss() or false
end

--- Run the lever's own spawn inside the private instance and bind what it created.
local function materializeLever(session, lever)
	ensureLeverHook()
	local instanceId = session.instance.instanceId
	local ok, spawned = lever:startEncounter({
		instanceId = instanceId,
		difficulty = session.bossDifficulty,
		playerIds = ExpeditionManager.sessionMemberIds(session),
	})
	if not ok then
		return
	end
	-- createFunction levers may return any of their spawns (`a and b and c` yields the
	-- last one, e.g. Ratmiral's Weak Spot) or none, so bind lever bosses from the arena.
	local bosses, primary = {}, nil
	local fallback = nil
	local seen = {}
	local function consider(monster, returned)
		if not monster or monster:getHealth() <= 0 or seen[monster:getId()] then
			return
		end
		seen[monster:getId()] = true
		if not isLeverBossMonster(monster, lever) then
			if returned then
				fallback = fallback or monster
			end
			return
		end
		local name = monster:getName():lower()
		if not primary and (name == lever.name or lever:isFinalBoss(name)) then
			primary = monster
		else
			bosses[#bosses + 1] = monster
		end
	end
	for _, monster in ipairs(spawned) do
		consider(monster, true)
	end
	for _, monster in ipairs(Game.getInstanceMonsters(instanceId)) do
		consider(monster)
	end
	-- Primary binds last so the HUD tracks it (bindBoss keeps the latest as bossCreatureId).
	bosses[#bosses + 1] = primary
	for _, monster in ipairs(bosses) do
		ExpeditionBoss.bindBoss(session, monster)
	end
	if session.alive == 0 and fallback then
		ExpeditionBoss.bindBoss(session, fallback)
	end
	if session.alive == 0 and not encounterDriven(lever) and not session.leverSpawnWarned then
		session.leverSpawnWarned = true
		logger.warn("[Expedition] lever {} spawned no boss in {}; retrying", lever.name, instanceId)
	end
end

--- Run the lever's stock encounter script as a copy owned by the session's instance; the
--- boss binds when the copy spawns it (later stage). Returns the copy, nil when it failed.
local function startLeverEncounter(session, lever)
	local instanceId = session.instance.instanceId
	local copy, reason = EncounterInstances.start(lever.encounter, instanceId, {
		scope = ExpeditionManager.scope(session),
		onSpawn = function(monster)
			if session.state == "hunting" and isLeverBossMonster(monster, lever) then
				ExpeditionBoss.bindBoss(session, monster)
				ExpeditionManager.broadcastStatus(session)
			end
		end,
	})
	if not copy then
		logger.error("[Expedition] encounter {} failed to start in {}: {}", lever.encounter, instanceId, tostring(reason))
	end
	return copy
end

local function materialize(session, planned)
	session.alive = 0
	session.state = "hunting"
	session.bossCreatureId = nil

	local lever = sessionLever(session)
	local encounterRunning = false
	if lever then
		materializeLever(session, lever)
		local copy = encounterDriven(lever) and startLeverEncounter(session, lever) or nil
		encounterRunning = copy ~= nil
		ExpeditionBossMechanics.start(session, lever, copy)
		planned = {}
	end
	for _, entry in ipairs(planned) do
		local monster = ExpeditionInstance.createMonsterExclusive
				and ExpeditionInstance.createMonsterExclusive(entry.name, entry.pos, session.instance)
			or Game.createMonster(entry.name, entry.pos, false, false, nil, session.instance.instanceId)
		if monster then
			monster:runHealth(0)
			ExpeditionBoss.bindBoss(session, monster)
		else
			logger.warn("[Expedition] failed to create boss '{}' at {}", entry.name, entry.pos)
		end
	end

	if session.alive == 0 and not encounterRunning then
		retrySpawn(session)
	else
		ExpeditionBoss.scheduleDespawn(session)
		ExpeditionManager.broadcastStatus(session)
	end
end

local function schedulePreSpawn(session, planned, remainingMs, intervalMs)
	if session.state ~= "waiting" then
		return
	end
	if not (session.instance and Instance.isLive(session.instance.instanceId)) then
		return
	end

	if remainingMs <= 0 then
		materialize(session, planned)
		return
	end

	for _, entry in ipairs(planned) do
		if ExpeditionInstance.sendMagicEffect then
			ExpeditionInstance.sendMagicEffect(session.instance, entry.pos, CONST_ME_TELEPORT)
		else
			entry.pos:sendMagicEffect(CONST_ME_TELEPORT)
		end
	end

	ExpeditionManager.scope(session):timer("bossSpawn", intervalMs, function()
		schedulePreSpawn(session, planned, remainingMs - intervalMs, intervalMs)
	end)
end

function ExpeditionBoss.spawn(session)
	if not session or not session.instance or not session.catalog then
		return
	end

	ExpeditionManager.scope(session):cancel("bossSpawn")
	clearDespawn(session)

	local raceId = session.catalog.creatureId
	if (not raceId or raceId <= 0) and type(session.catalog.creatureIds) == "table" then
		raceId = session.catalog.creatureIds[1]
	end

	-- A lever fight is already set up when the party arrives (the stock lever spawns, then
	-- teleports), so it runs the lever's own spawn right away: no expedition spawn flash.
	local lever = sessionLever(session)
	if lever then
		session.wave = 1
		session.state = "waiting"
		session.alive = 0
		session.bossCreatureId = nil
		session.bossRaceId = raceId
		materialize(session, {})
		return
	end
	-- Prefer catalog.name so shared bosstiary race ids (multi-phase forms) spawn the right type.
	local bossName = ExpeditionConfig.monsterNameByCreatureId(nil, session.catalog.name)
		or ExpeditionConfig.monsterNameByCreatureId(raceId, session.catalog.name)
	if not bossName then
		logger.warn(
			"[Expedition] boss hunt {} missing monster type (creatureId={} name={})",
			session.catalog.id or "?",
			tostring(raceId),
			tostring(session.catalog.name)
		)
		retrySpawn(session)
		ExpeditionManager.broadcastStatus(session)
		return
	end
	local pos = bossSpawnPos(session)
	if not pos then
		retrySpawn(session)
		ExpeditionManager.broadcastStatus(session)
		return
	end

	session.wave = 1
	session.state = "waiting"
	session.alive = 0
	session.bossCreatureId = nil
	session.bossRaceId = raceId

	local planned = { { name = bossName, pos = Position(pos.x, pos.y, pos.z) } }
	ExpeditionManager.broadcastStatus(session)

	local durationMs, _, intervalMs = preSpawnDurationMs()
	schedulePreSpawn(session, planned, durationMs, intervalMs)
end

--- Lever boss session fighting in `creature`'s instance when `creature` is that lever's
--- final boss (covers forms the session never bound, e.g. script-respawned ones).
local function unownedFinalBossSession(creature)
	if not creature.getInstanceId or not ExpeditionManager.getSessionByInstanceId then
		return nil
	end
	local session = ExpeditionManager.getSessionByInstanceId(creature:getInstanceId())
	if not session or session.state ~= "hunting" then
		return nil
	end
	local lever = sessionLever(session)
	if lever and lever:isFinalBoss(creature:getName()) then
		return session
	end
	return nil
end

function ExpeditionBoss.onMonsterDeath(creature, corpse)
	if not creature then
		return false
	end
	local monsterId = creature:getId()
	local key = bossOwners[monsterId]
	local session = nil
	if key then
		bossOwners[monsterId] = nil
		session = ExpeditionManager.getSessionByKey(key)
		if not session then
			return true
		end
	else
		session = unownedFinalBossSession(creature)
		if not session then
			return false
		end
		key = session.key
	end
	if session.bossCreatureId == monsterId then
		session.bossCreatureId = nil
	end

	local lever = sessionLever(session)
	if lever then
		if lever:isFinalBoss(creature:getName()) then
			session.kills = (session.kills or 0) + 1
			finishBoss(session, { victory = true })
			return true
		end
		-- Chained fights continue until the final form dies; its spawn rebinds the session.
		if lever:isChained() then
			return true
		end
	end

	-- Every bound boss must die. Phase swaps either remove() the old form (never reaching
	-- onDeath) or kill a corpse-less mid-form and spawn the next one, so check on the
	-- next tick whether any boss (or a same-race replacement form) is still alive.
	session.alive = 0
	ExpeditionManager.scope(session):after(SCHEDULER_MIN_TICKS or 50, function()
		if session.state ~= "hunting" or ExpeditionBoss.rebindBossIfNeeded(session) then
			return
		end
		session.kills = (session.kills or 0) + 1
		finishBoss(session, { victory = true })
	end)
	return true
end

IdleEvents.on("monster.died", ExpeditionBoss.onMonsterDeath, "ExpeditionBoss")

function ExpeditionBoss.clear(session)
	if not session then
		return
	end
	ExpeditionManager.scope(session):cancel("bossSpawn")
	clearDespawn(session)
	stopEncounterCopy(session)
	ExpeditionBossMechanics.stop(session)
	local lever = sessionLever(session)
	if lever and session.instance then
		lever:clearEncounter(session.instance.instanceId)
	end
	for mid, key in pairs(bossOwners) do
		if key == session.key then
			bossOwners[mid] = nil
			local monster = Monster(mid)
			if monster then
				monster:remove()
			end
		end
	end
	session.alive = 0
	session.bossCreatureId = nil
end

function ExpeditionBoss.getBoss(session)
	if not session then
		return nil
	end
	if session.bossCreatureId then
		local creature = Creature(session.bossCreatureId)
		if creature and creature:isMonster() and creature:getHealth() > 0 then
			return creature
		end
	end
	return ExpeditionBoss.rebindBossIfNeeded(session)
end
