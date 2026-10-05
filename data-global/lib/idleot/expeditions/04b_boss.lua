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
	if session and session.despawnEvent then
		stopEvent(session.despawnEvent)
		session.despawnEvent = nil
	end
	if session then
		session.bossEndsAt = nil
		session.bossTimeLimitSec = nil
	end
end

--- HEALTHCHANGE kill-gates only (phase transforms must stay registered).
--- tentuglysHeadPhase: CIP tentacle teleport/arena (absolute multi-floor).
--- facelessHealth: CIP immortality / elemental absorb cleared only by arena tiles.
local KILL_GATE_HEALTHCHANGE = {
	["monster.invulnerable"] = true,
	["tentuglysHeadPhase"] = true,
	["facelessHealth"] = true,
}

--- Neutralize scripts that block HP from reaching 0. Keeps THINK (heals/summons).
--- Always preserves non-kill-gate HEALTHCHANGE (e.g. UrmahlulluChanges phase transforms).
function ExpeditionBoss.ensureKillable(monster, _opts)
	if not monster then
		return false
	end
	for i = 1, #KILL_GATE_EVENT_TYPES do
		local eventType = KILL_GATE_EVENT_TYPES[i]
		if eventType ~= nil then
			local events = monster:getEvents(eventType)
			if type(events) == "table" then
				for j = 1, #events do
					local name = events[j]
					if name and name ~= "" then
						local strip = true
						if eventType == CREATURE_EVENT_HEALTHCHANGE then
							strip = KILL_GATE_HEALTHCHANGE[name] == true
						end
						if strip then
							monster:unregisterEvent(name)
						end
					end
				end
			end
		end
	end
	pcall(function()
		monster:immune(false)
	end)
	return true
end

--- True when the boss still has kill-gate scripts attached.
function ExpeditionBoss.hasKillGates(monster, _opts)
	if not monster then
		return false
	end
	for i = 1, #KILL_GATE_EVENT_TYPES do
		local eventType = KILL_GATE_EVENT_TYPES[i]
		if eventType ~= nil then
			local events = monster:getEvents(eventType)
			if type(events) == "table" then
				for j = 1, #events do
					local name = events[j]
					if name and name ~= "" then
						if eventType == CREATURE_EVENT_HEALTHCHANGE then
							if KILL_GATE_HEALTHCHANGE[name] then
								return true
							end
						else
							return true
						end
					end
				end
			end
		end
	end
	return false
end

function ExpeditionBoss.ensureKillableSession(session)
	if ExpeditionConfig.bossLever(session and session.catalog) then
		return false
	end
	local boss = ExpeditionBoss.getBoss(session)
	if not boss or not ExpeditionBoss.hasKillGates(boss) then
		return false
	end
	return ExpeditionBoss.ensureKillable(boss)
end

local function sessionLever(session)
	return session and session.catalog and ExpeditionConfig.bossLever(session.catalog) or nil
end

--- Phase transforms remove+recreate the monster; re-bind ownership to the new form.
--- Lever fights run in the lever's own arena, so its kill-gates stay and forms fought
--- together keep their owner entries.
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
	monster:registerEvent("ExpeditionMonsterDeath")
	if not lever then
		ExpeditionBoss.ensureKillable(monster)
	end
	return true
end

--- Optional hook if a Crystal script notifies after remove()+createMonster.
--- Expedition also rebinds by shared bossRaceId in getBoss/rebindBossIfNeeded.
function ExpeditionBoss.onPhaseSpawned(monster)
	if not monster or not monster.getInstanceId or not ExpeditionManager then
		return false
	end
	local instanceId = monster:getInstanceId()
	if not instanceId or instanceId == 0 then
		return false
	end

	local seen = {}
	for _, ownerKey in pairs(bossOwners) do
		if ownerKey and not seen[ownerKey] then
			seen[ownerKey] = true
			local session = ExpeditionManager.getSessionByKey(ownerKey)
			if (
				session
				and session.state == "hunting"
				and session.instance
				and session.instance.instanceId == instanceId
			) then
				local role = session.role or (session.catalog and session.catalog.role)
				if role == "boss" then
					return ExpeditionBoss.bindBoss(session, monster)
				end
			end
		end
	end
	return false
end

--- BossLever:spawnForm hook: later forms of a chained lever fight join the session
--- running that lever in the form's instance.
local function onLeverFormSpawned(monster, lever)
	if not monster or not monster.getInstanceId or not ExpeditionManager then
		return
	end
	local instanceId = monster:getInstanceId()
	if not instanceId or instanceId == 0 then
		return
	end
	local session = ExpeditionManager.getSessionByInstanceId(instanceId)
	if session and session.state == "hunting" and sessionLever(session) == lever then
		ExpeditionBoss.bindBoss(session, monster)
	end
end

if BossLever and BossLever.addPhaseHook and not ExpeditionBoss.leverHookAdded then
	ExpeditionBoss.leverHookAdded = true
	BossLever.addPhaseHook(function(monster, lever)
		onLeverFormSpawned(monster, lever)
	end)
end

function ExpeditionBoss.rebindBossIfNeeded(session)
	if not session or session.state ~= "hunting" then
		return nil
	end
	local instanceId = session.instance and session.instance.instanceId
	if not instanceId or not Game.getMonsters then
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
	for _, monster in ipairs(Game.getMonsters()) do
		if monster and monster:getHealth() > 0 and monster.getInstanceId and monster:getInstanceId() == instanceId then
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
	if not instanceId or instanceId == 0 or not Game.getMonsters then
		return
	end
	addEvent(function()
		if Game.clearInstanceSpawns then
			Game.clearInstanceSpawns(instanceId)
		end
		for _, monster in ipairs(Game.getMonsters()) do
			if monster:getInstanceId() == instanceId and monster:getHealth() > 0 then
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

	for _, mid in ipairs(ExpeditionManager.sessionMemberIds(session)) do
		local member = Player(mid)
		if member then
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
	end

	if session.waitingEvent then
		stopEvent(session.waitingEvent)
		session.waitingEvent = nil
	end

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
	session.despawnEvent = addEvent(function()
		local s = ExpeditionManager.getSessionByKey(key)
		if not s or s.state ~= "hunting" then
			return
		end
		s.despawnEvent = nil
		local bossId = s.bossCreatureId
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
		finishBoss(s, { victory = false })
	end, sec * 1000)
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
	if Game.getMonsters then
		for _, monster in ipairs(Game.getMonsters()) do
			if monster:getInstanceId() == instanceId then
				consider(monster)
			end
		end
	end
	-- Primary binds last so the HUD tracks it (bindBoss keeps the latest as bossCreatureId).
	bosses[#bosses + 1] = primary
	for _, monster in ipairs(bosses) do
		ExpeditionBoss.bindBoss(session, monster)
	end
	if session.alive == 0 and fallback then
		ExpeditionBoss.bindBoss(session, fallback)
	end
end

local function materialize(session, planned)
	session.waitingEvent = nil
	session.alive = 0
	session.state = "hunting"
	session.bossCreatureId = nil

	local lever = sessionLever(session)
	if lever then
		materializeLever(session, lever)
		planned = {}
	end
	for _, entry in ipairs(planned) do
		local monster = ExpeditionInstance.createMonsterExclusive
				and ExpeditionInstance.createMonsterExclusive(entry.name, entry.pos, session.instance)
			or Game.createMonster(entry.name, entry.pos, false, false)
		if monster then
			monster:runHealth(0)
			ExpeditionBoss.bindBoss(session, monster)
		else
			logger.warn("[Expedition] failed to create boss '{}' at {}", entry.name, entry.pos)
		end
	end

	if session.alive == 0 then
		session.state = "waiting"
		session.waitingEvent = addEvent(function()
			local s = ExpeditionManager.getSessionByKey(session.key)
			if s then
				ExpeditionBoss.spawn(s)
			end
		end, 1500)
	else
		ExpeditionBoss.scheduleDespawn(session)
		ExpeditionManager.broadcastStatus(session)
	end
end

local function schedulePreSpawn(sessionKey, planned, remainingMs, intervalMs)
	local session = ExpeditionManager.getSessionByKey(sessionKey)
	if not session or session.state ~= "waiting" then
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

	session.waitingEvent = addEvent(function()
		schedulePreSpawn(sessionKey, planned, remainingMs - intervalMs, intervalMs)
	end, intervalMs)
end

function ExpeditionBoss.spawn(session)
	if not session or not session.instance or not session.catalog then
		return
	end

	if session.waitingEvent then
		stopEvent(session.waitingEvent)
		session.waitingEvent = nil
	end
	clearDespawn(session)

	local raceId = session.catalog.creatureId
	if (not raceId or raceId <= 0) and type(session.catalog.creatureIds) == "table" then
		raceId = session.catalog.creatureIds[1]
	end

	local lever = sessionLever(session)
	if lever then
		local flashPos = lever.bossPosition or session.instance.entry
		session.wave = 1
		session.state = "waiting"
		session.alive = 0
		session.bossCreatureId = nil
		session.bossRaceId = raceId
		ExpeditionManager.broadcastStatus(session)
		local durationMs, _, intervalMs = preSpawnDurationMs()
		schedulePreSpawn(session.key, { { name = lever.name, pos = Position(flashPos.x, flashPos.y, flashPos.z) } }, durationMs, intervalMs)
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
		session.state = "waiting"
		session.waitingEvent = addEvent(function()
			local s = ExpeditionManager.getSessionByKey(session.key)
			if s then
				ExpeditionBoss.spawn(s)
			end
		end, 1500)
		ExpeditionManager.broadcastStatus(session)
		return
	end
	local pos = bossSpawnPos(session)
	if not pos then
		session.state = "waiting"
		session.waitingEvent = addEvent(function()
			local s = ExpeditionManager.getSessionByKey(session.key)
			if s then
				ExpeditionBoss.spawn(s)
			end
		end, 1500)
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
	schedulePreSpawn(session.key, planned, durationMs, intervalMs)
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
	addEvent(function()
		local s = ExpeditionManager.getSessionByKey(key)
		if not s or s.state ~= "hunting" then
			return
		end
		if ExpeditionBoss.rebindBossIfNeeded(s) then
			return
		end
		s.kills = (s.kills or 0) + 1
		finishBoss(s, { victory = true })
	end, SCHEDULER_MIN_TICKS or 50)
	return true
end

function ExpeditionBoss.clear(session)
	if not session then
		return
	end
	if session.waitingEvent then
		stopEvent(session.waitingEvent)
		session.waitingEvent = nil
	end
	clearDespawn(session)
	if session.instance and session.instance.zone then
		session.instance.zone:removeMonsters()
	end
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
