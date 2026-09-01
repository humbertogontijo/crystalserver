ExpeditionBoss = ExpeditionBoss or {}

-- monsterId -> session key (boss fights share death event with waves)
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
end

--- HEALTHCHANGE kill-gates only (phase transforms must stay registered).
local KILL_GATE_HEALTHCHANGE = {
	["monster.invulnerable"] = true,
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
	local boss = ExpeditionBoss.getBoss(session)
	if not boss or not ExpeditionBoss.hasKillGates(boss) then
		return false
	end
	return ExpeditionBoss.ensureKillable(boss)
end

--- Phase transforms remove+recreate the monster; re-bind ownership to the new form.
function ExpeditionBoss.bindBoss(session, monster)
	if not session or not monster then
		return false
	end
	local mid = monster:getId()
	-- Drop stale owner entries for this session (previous phase creature ids).
	for id, ownerKey in pairs(bossOwners) do
		if ownerKey == session.key and id ~= mid then
			bossOwners[id] = nil
		end
	end
	bossOwners[mid] = session.key
	session.bossCreatureId = mid
	session.alive = 1
	session.phaseTransform = nil
	monster:registerEvent("ExpeditionMonsterDeath")
	ExpeditionBoss.ensureKillable(monster)
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

--- Shared overtime / victory end: loot delay then leave (or teardown if everyone offline).
local function finishBoss(session, opts)
	opts = opts or {}
	local victory = opts.victory == true
	local key = session.key

	clearDespawn(session)
	session.alive = 0
	session.bossCreatureId = nil
	session.state = "waiting"
	ExpeditionManager.broadcastStatus(session)

	local midMsg = victory and "Boss defeated! Looting..." or "Time expired! Expedition failed."
	local endMsg = victory and "Expedition complete." or "Expedition failed."

	for _, mid in ipairs(ExpeditionManager.sessionMemberIds(session)) do
		local member = Player(mid)
		if member then
			member:setFollowCreature(nil)
			member:setTarget(nil)
			member:sendTextMessage(MESSAGE_EVENT_ADVANCE, midMsg)
			if ExpeditionConfig and ExpeditionConfig.clearBossAttempt then
				ExpeditionConfig.clearBossAttempt(member)
			end
			if victory and ActivityBoostActivities and ActivityBoostActivities.onBossExpeditionVictory then
				pcall(ActivityBoostActivities.onBossExpeditionVictory, member)
			end
			if victory and ActivityBoostSoloBoss and ActivityBoostSoloBoss.onBossClear then
				local clearSec = 0
				if session.startedAt then
					clearSec = math.max(0, os.time() - session.startedAt)
				end
				local expeditionId = session.catalog and session.catalog.id
				pcall(ActivityBoostSoloBoss.onBossClear, member, expeditionId, clearSec)
			end
		end
	end

	if session.waitingEvent then
		stopEvent(session.waitingEvent)
		session.waitingEvent = nil
	end

	session.waitingEvent = addEvent(function()
		local s = ExpeditionManager.getSessionByKey(key)
		if not s then
			return
		end
		local anyOnline = false
		for _, mid in ipairs(ExpeditionManager.sessionMemberIds(s)) do
			local p = Player(mid)
			if p then
				anyOnline = true
			end
		end
		if anyOnline and ExpeditionManager.leaveAll then
			for _, mid in ipairs(ExpeditionManager.sessionMemberIds(s)) do
				local p = Player(mid)
				if p then
					p:sendTextMessage(MESSAGE_EVENT_ADVANCE, endMsg)
				end
			end
			ExpeditionManager.leaveAll(s, { silent = true, victory = victory })
		elseif anyOnline then
			local host = s.playerId and Player(s.playerId) or nil
			if host then
				host:sendTextMessage(MESSAGE_EVENT_ADVANCE, endMsg)
				ExpeditionManager.leave(host, { silent = true, victory = victory })
			else
				ExpeditionManager.teardownSession(s)
			end
		else
			ExpeditionManager.teardownSession(s)
		end
	end, ExpeditionConfig.BOSS_END_DELAY_MS or 2500)
end

--- Lever-style timeToDefeat: despawn boss and fail the expedition (overtime).
function ExpeditionBoss.scheduleDespawn(session)
	if not session then
		return
	end
	clearDespawn(session)
	local key = session.key
	local sec = ExpeditionConfig.bossTimeToDefeatSec and ExpeditionConfig.bossTimeToDefeatSec()
		or ExpeditionConfig.BOSS_TIME_TO_DEFEAT_SEC
		or (20 * 60)
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
	end, math.floor(sec) * 1000)
end

local function materialize(session, planned)
	session.waitingEvent = nil
	session.alive = 0
	session.state = "hunting"
	session.bossCreatureId = nil

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
	session.waveLure = nil
	session.state = "waiting"
	session.alive = 0
	session.bossCreatureId = nil
	session.bossRaceId = raceId

	local planned = { { name = bossName, pos = Position(pos.x, pos.y, pos.z) } }
	ExpeditionManager.broadcastStatus(session)

	local durationMs, _, intervalMs = preSpawnDurationMs()
	schedulePreSpawn(session.key, planned, durationMs, intervalMs)
end

function ExpeditionBoss.onMonsterDeath(creature, corpse)
	if not creature then
		return false
	end
	local monsterId = creature:getId()
	local key = bossOwners[monsterId]
	if not key then
		return false
	end
	bossOwners[monsterId] = nil

	local session = ExpeditionManager.getSessionByKey(key)
	if not session then
		return true
	end

	-- Phase swaps use creature:remove() and never reach onDeath. Real deaths run
	-- dropCorpse → onDeath(corpse). Only end the expedition when a body is placed
	-- (e.g. Urmahlullu Weakened has a corpse; mid-forms have corpse = 0).
	if not corpse then
		session.bossCreatureId = nil
		session.alive = 0
		addEvent(function()
			local s = ExpeditionManager.getSessionByKey(key)
			if not s or s.state ~= "hunting" then
				return
			end
			if ExpeditionBoss.rebindBossIfNeeded(s) then
				return
			end
			-- True death with no corpse item (monster.corpse = 0): still complete.
			s.kills = (s.kills or 0) + 1
			finishBoss(s, { victory = true })
		end, SCHEDULER_MIN_TICKS or 50)
		return true
	end

	session.kills = (session.kills or 0) + 1
	finishBoss(session, { victory = true })
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
