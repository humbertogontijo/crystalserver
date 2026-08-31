ExpeditionWaves = ExpeditionWaves or {}

-- monsterId -> session key
local monsterOwners = {}

local function huntEnded(session)
	return not session or session.state == "ended"
end

local function catalogCreatureIds(catalog)
	if not catalog then
		return {}
	end
	if type(catalog.creatureIds) == "table" and #catalog.creatureIds > 0 then
		return catalog.creatureIds
	end
	if catalog.creatureId and catalog.creatureId > 0 then
		return { catalog.creatureId }
	end
	return {}
end

--- Weighted pick from catalog.creatures percents (sum 100). Falls back to equal creatureIds.
local function pickCreatureId(catalog)
	local creatures = catalog and catalog.creatures
	if type(creatures) == "table" and #creatures > 0 then
		local total = 0
		for _, entry in ipairs(creatures) do
			local pct = math.floor(tonumber(entry.percent) or 0)
			if pct > 0 and entry.creatureId and entry.creatureId > 0 then
				total = total + pct
			end
		end
		if total > 0 then
			local roll = math.random(1, total)
			local acc = 0
			for _, entry in ipairs(creatures) do
				local pct = math.floor(tonumber(entry.percent) or 0)
				if pct > 0 and entry.creatureId and entry.creatureId > 0 then
					acc = acc + pct
					if roll <= acc then
						return entry.creatureId
					end
				end
			end
			local last = creatures[#creatures]
			if last and last.creatureId and last.creatureId > 0 then
				return last.creatureId
			end
		end
	end
	local ids = catalogCreatureIds(catalog)
	if #ids == 0 then
		return nil
	end
	return ids[math.random(1, #ids)]
end

--- Always spawn on the live anchor so waves appear where the party actually is.
--- Catalog holdPos is only for walking between waves, never for monster placement.
local function spawnCenter(session)
	local anchor = ExpeditionConfig.getAnchorPlayer and ExpeditionConfig.getAnchorPlayer(session)
	if anchor then
		return anchor:getPosition()
	end
	local player = session.playerId and Player(session.playerId) or nil
	if player then
		return player:getPosition()
	end
	if session and session.holdPos then
		return session.holdPos
	end
	return session.instance and session.instance.entry or nil
end

--- True when the anchor stands on the hold tile (exact).
local function anchorAtHold(session)
	local hold = session and session.holdPos
	if not hold then
		return true
	end
	local anchor = ExpeditionConfig.getAnchorPlayer and ExpeditionConfig.getAnchorPlayer(session)
	if not anchor then
		return false
	end
	local p = anchor:getPosition()
	return p and p.x == hold.x and p.y == hold.y and p.z == hold.z
end

local function preSpawnDurationMs()
	local flashes = ExpeditionConfig.PRE_SPAWN_FLASHES or 3
	local interval = ExpeditionConfig.PRE_SPAWN_INTERVAL_MS or 1400
	return flashes * interval, flashes, interval
end

local function lureCount(session)
	local count = ExpeditionConfig.normalizeLure(session and session.lure)
	return count
end

local function clearWaiting(session)
	if session and session.waitingEvent then
		stopEvent(session.waitingEvent)
		session.waitingEvent = nil
	end
end

local function clearRelocate(session)
	if session and session.relocateEvent then
		stopEvent(session.relocateEvent)
		session.relocateEvent = nil
	end
	if session and session.relocateTimeoutEvent then
		stopEvent(session.relocateTimeoutEvent)
		session.relocateTimeoutEvent = nil
	end
	if session and session.relocateReadyEvent then
		stopEvent(session.relocateReadyEvent)
		session.relocateReadyEvent = nil
	end
	if session and session.relocateWalkEvent then
		stopEvent(session.relocateWalkEvent)
		session.relocateWalkEvent = nil
	end
	if session then
		session.relocatePath = nil
		session.relocatePathIndex = nil
		session.relocateSpawnScheduled = nil
		session.relocateCanSpawn = nil
		session.relocateDelayMs = nil
		session._relocateAutoQueued = nil
		session._relocateLastPos = nil
		session._relocateStall = nil
		session._relocateStallMs = nil
		session._relocateMember = nil
		session._relocateDestsAssigned = nil
		session._relocateFollowReady = nil
		if ExpeditionAI and ExpeditionAI.clearCatchUpBoosts then
			ExpeditionAI.clearCatchUpBoosts(session)
		end
	end
end

--- Advance to the next catalog hold (round-robin). Returns true when the party should walk.
--- positionIndex 0 = first wave at instance.entry (not yet on the catalog cycle).
local function advanceHold(session)
	if not session or not session.catalog then
		return false
	end
	if session.role and session.role ~= "monster" then
		return false
	end
	if not ExpeditionConfig.canRelocateHolds or not ExpeditionConfig.canRelocateHolds(session.catalog) then
		return false
	end
	local holds = ExpeditionConfig.catalogPositions(session.catalog)
	if #holds < 2 then
		return false
	end
	local idx = tonumber(session.positionIndex) or 0
	local nextIdx = idx < 1 and 1 or ((idx % #holds) + 1)
	local nextHold = holds[nextIdx]
	if not nextHold then
		return false
	end
	-- Occupancy-safe path from the hold we are leaving (routes[idx]: hold[idx] → hold[next]).
	session.relocatePath = nil
	session.relocatePathIndex = nil
	if idx >= 1 and ExpeditionConfig.holdRoutes then
		local routes = ExpeditionConfig.holdRoutes(session.catalog)
		local route = type(routes) == "table" and routes[idx] or nil
		if type(route) == "table" and #route > 0 then
			session.relocatePath = route
			session.relocatePathIndex = 1
		end
	end
	session.positionIndex = nextIdx
	session.holdPos = Position(nextHold.x, nextHold.y, nextHold.z)
	return true
end

--- Teleport session members onto holdPos so a timed-out relocate can still spawn.
--- Must use enterInstance (skips open-world travel classify) - raw teleportTo would
--- treat Rookgaard-overlapping holds as settlement leave and strand the party outside PZ.
local function forceArriveAtHold(session)
	local hold = session and session.holdPos
	if not hold or not ExpeditionManager or not ExpeditionManager.sessionMemberIds then
		return
	end
	local instanceId = session.instance and session.instance.instanceId
	for _, mid in ipairs(ExpeditionManager.sessionMemberIds(session)) do
		local p = Player(mid)
		if p then
			p:setFollowCreature(nil)
			local ok = false
			if InstanceWorld and InstanceWorld.enterInstance and instanceId then
				ok = InstanceWorld.enterInstance(p, instanceId, hold) and true or false
			elseif p.setInstanceId and instanceId then
				p:setInstanceId(instanceId)
				ok = p:teleportTo(hold) and true or false
			else
				ok = p:teleportTo(hold) and true or false
			end
			if not ok then
				logger.warn(
					"[Expedition] forceArrive teleport failed for {} → {}",
					p:getName(),
					string.format("%d,%d,%d", hold.x, hold.y, hold.z)
				)
			end
		end
	end
end

local function planWave(session, count)
	local center = spawnCenter(session)
	if not center then
		return {}
	end
	local planned = {}
	local reserved = {}
	for _ = 1, count do
		local creatureId = pickCreatureId(session.catalog)
		if not creatureId then
			break
		end
		local name = ExpeditionConfig.monsterNameByCreatureId(creatureId)
		if name then
			-- Adjacent to the hold/anchor, including ranged (targetDistance is combat-only).
			-- Full-hunt occupancy is the walkable map; lure waves still spawn on the party.
			local pos = ExpeditionInstance.randomAttackRangeWalkable(session.instance, center, 1, reserved)
			if pos then
				ExpeditionInstance.reservePos(reserved, pos)
				planned[#planned + 1] = {
					creatureId = creatureId,
					name = name,
					pos = Position(pos.x, pos.y, pos.z),
				}
			end
		end
	end
	return planned
end

local function materialize(session, planned)
	if huntEnded(session) then
		return
	end
	session.waitingEvent = nil
	session.alive = 0
	session.state = "hunting"

	for _, entry in ipairs(planned) do
		local monster = ExpeditionInstance.createMonsterExclusive
				and ExpeditionInstance.createMonsterExclusive(entry.name, entry.pos, session.instance)
			or Game.createMonster(entry.name, entry.pos, false, false)
		if monster then
			-- Never flee (runAwayHealth); ranged targetDistance / distance attacking is unchanged.
			monster:runHealth(0)
			monster:registerEvent("ExpeditionMonsterDeath")
			monsterOwners[monster:getId()] = session.key
			session.alive = session.alive + 1
		else
			logger.warn(
				"[Expedition] failed to create monster race {} ('{}') at {}",
				entry.creatureId,
				entry.name,
				entry.pos
			)
		end
	end

	if session.alive == 0 then
		-- Retry shortly if spawn failed (tiles not ready yet).
		session.state = "waiting"
		session.waitingEvent = addEvent(function()
			local s = ExpeditionManager.getSessionByKey(session.key)
			if s and not huntEnded(s) then
				ExpeditionWaves.spawn(s)
			end
		end, 1500)
	else
		ExpeditionWaves.scheduleDespawn(session)
		ExpeditionManager.broadcastStatus(session)
	end
end

local function clearDespawn(session)
	if session and session.despawnEvent then
		stopEvent(session.despawnEvent)
		session.despawnEvent = nil
	end
end

-- Mirror SpawnMonster::scheduleSpawn: flash CONST_ME_TELEPORT at each tile, then place.
local function schedulePreSpawn(sessionKey, planned, remainingMs, intervalMs)
	local session = ExpeditionManager.getSessionByKey(sessionKey)
	if huntEnded(session) then
		return
	end
	if not session or (session.state ~= "waiting" and session.state ~= "relocating") then
		return
	end

	if remainingMs <= 0 then
		materialize(session, planned)
		return
	end

	session.state = "waiting"
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

-- Forward declarations (scheduleSpawnAfterArrival / poll / beginSpawn call each other).
local pollRelocateThenSpawn
local beginSpawnOnceSettled

--- After the party is settled on the hold: wait the respawn delay, then spawn.
--- State may already be "waiting" (hunt formation) while this countdown runs.
local function scheduleSpawnAfterArrival(session)
	if not session then
		return
	end
	if session.state ~= "relocating" and session.state ~= "waiting" then
		return
	end
	if session.relocateSpawnScheduled then
		return
	end
	session.relocateSpawnScheduled = true
	local key = session.key
	local delay = math.max(0, tonumber(session.relocateDelayMs) or 0)
	if delay <= 0 then
		beginSpawnOnceSettled(session)
		return
	end
	session.relocateReadyEvent = addEvent(function()
		local s = ExpeditionManager.getSessionByKey(key)
		if not s or (s.state ~= "relocating" and s.state ~= "waiting") then
			return
		end
		if not anchorAtHold(s) then
			-- Left the hold before the delay finished - wait to arrive again.
			s.relocateSpawnScheduled = nil
			s._relocateFollowReady = nil
			s.state = "relocating"
			s.relocateEvent = addEvent(function()
				pollRelocateThenSpawn(key)
			end, ExpeditionConfig.AI_TICK_MS or 250)
			return
		end
		beginSpawnOnceSettled(s)
	end, delay)
end

--- Party / anchor finished relocate to hold: enter waiting (hunt formation) immediately,
--- then start the spawn delay. Monsters still wait relocateDelayMs / pre-spawn flashes.
function ExpeditionWaves.onRelocatePartySettled(session)
	if not session then
		return
	end
	if session.state ~= "relocating" and session.state ~= "waiting" then
		return
	end
	if session.state == "relocating" then
		session.state = "waiting"
		ExpeditionManager.broadcastStatus(session)
	end
	-- Stop the relocate walk loop so companions switch to formation AI this tick.
	if session.relocateWalkEvent then
		stopEvent(session.relocateWalkEvent)
		session.relocateWalkEvent = nil
	end
	scheduleSpawnAfterArrival(session)
end

--- Poll until the anchor is on holdPos, then switch to waiting + spawn delay.
--- Companions catch up via hunt formation after state leaves relocating (do not
--- block the wave on exact stance tiles - collision can soft-lock that forever).
pollRelocateThenSpawn = function(sessionKey)
	local session = ExpeditionManager.getSessionByKey(sessionKey)
	if not session or session.state ~= "relocating" then
		return
	end

	if anchorAtHold(session) then
		session._relocateFollowReady = true
		ExpeditionWaves.onRelocatePartySettled(session)
		return
	end

	session.relocateEvent = addEvent(function()
		pollRelocateThenSpawn(sessionKey)
	end, ExpeditionConfig.AI_TICK_MS or 250)
end

beginSpawnOnceSettled = function(session)
	if huntEnded(session) then
		return
	end
	-- Hard gate: never start a wave while still walking to the hold.
	if session.holdPos and not anchorAtHold(session) then
		logger.warn("[Expedition] spawn blocked - anchor not at hold yet")
		session.relocateSpawnScheduled = nil
		session._relocateFollowReady = nil
		session.state = "relocating"
		-- Ensure a walk is running (first-wave / resume paths may only poll otherwise).
		if ExpeditionAI and ExpeditionAI.startRelocateWalk then
			ExpeditionAI.startRelocateWalk(session)
		end
		if not session.relocateEvent then
			session.relocateEvent = addEvent(function()
				pollRelocateThenSpawn(session.key)
			end, ExpeditionConfig.AI_TICK_MS or 250)
		end
		return
	end
	clearWaiting(session)
	clearRelocate(session)

	local count = lureCount(session)
	session.waveLure = count
	session.wave = (session.wave or 0) + 1
	session.state = "waiting"
	session.alive = 0

	-- Reject catalog holds that cannot host a lure ring; skip to the next hold.
	local anchor = spawnCenter(session)
	if anchor and ExpeditionInstance and ExpeditionInstance.hasLureSpawnRing then
		if not ExpeditionInstance.hasLureSpawnRing(session.instance, anchor) then
			logger.warn("[Expedition] hold lacks lure spawn ring; advancing hold")
			if advanceHold(session) then
				session.waitingEvent = addEvent(function()
					local s = ExpeditionManager.getSessionByKey(session.key)
					if s and not huntEnded(s) then
						ExpeditionWaves.spawn(s)
					end
				end, 250)
			else
				session.waitingEvent = addEvent(function()
					local s = ExpeditionManager.getSessionByKey(session.key)
					if s and not huntEnded(s) then
						ExpeditionWaves.spawn(s)
					end
				end, 1500)
			end
			ExpeditionManager.broadcastStatus(session)
			return
		end
	end

	local planned = planWave(session, count)
	if #planned == 0 then
		logger.warn("[Expedition] wave plan empty at anchor; advancing hold")
		if advanceHold(session) then
			session.waitingEvent = addEvent(function()
				local s = ExpeditionManager.getSessionByKey(session.key)
				if s and not huntEnded(s) then
					ExpeditionWaves.spawn(s)
				end
			end, 250)
		else
			session.waitingEvent = addEvent(function()
				local s = ExpeditionManager.getSessionByKey(session.key)
				if s and not huntEnded(s) then
					ExpeditionWaves.spawn(s)
				end
			end, 1500)
		end
		ExpeditionManager.broadcastStatus(session)
		return
	end

	ExpeditionManager.broadcastStatus(session)

	local durationMs, _, intervalMs = preSpawnDurationMs()
	schedulePreSpawn(session.key, planned, durationMs, intervalMs)
end

--- After a cleared/despawned wave: optionally walk to the next hold, then spawn.
local function scheduleNextWave(session)
	if huntEnded(session) then
		return
	end
	clearWaiting(session)
	clearRelocate(session)

	local key = session.key
	local totalDelay = session.catalog and session.catalog.spawnIntervalMs or ExpeditionConfig.WAVE_RESPAWN_MS
	local preMs = preSpawnDurationMs()
	local delay = math.max(0, totalDelay - preMs)

	local shouldWalk = advanceHold(session)
	if shouldWalk then
		session.state = "relocating"
		session.relocateDelayMs = delay
		session.relocateSpawnScheduled = nil
		-- relocatePath / relocatePathIndex set by advanceHold (catalog occupancy route).
		local timeout = ExpeditionConfig.relocateTimeoutMs and ExpeditionConfig.relocateTimeoutMs()
			or ExpeditionConfig.RELOCATE_TIMEOUT_MS
			or 45000
		ExpeditionManager.broadcastStatus(session)
		-- Walk first; only after the anchor stands on the hold do we start the respawn delay.
		if ExpeditionAI and ExpeditionAI.startRelocateWalk then
			ExpeditionAI.startRelocateWalk(session)
		end
		session.relocateEvent = addEvent(function()
			pollRelocateThenSpawn(key)
		end, ExpeditionConfig.AI_TICK_MS or 250)
		session.relocateTimeoutEvent = addEvent(function()
			local s = ExpeditionManager.getSessionByKey(key)
			if not s or s.state ~= "relocating" then
				return
			end
			if anchorAtHold(s) then
				return
			end
			local hold = s.holdPos
			logger.warn(
				"[Expedition] relocate timeout - forcing spawn at hold {}",
				hold and string.format("%d,%d,%d", hold.x, hold.y, hold.z) or "?"
			)
			s.relocateTimeoutEvent = nil
			forceArriveAtHold(s)
			ExpeditionWaves.onRelocatePartySettled(s)
		end, timeout)
		return
	end

	session.state = "waiting"
	session.waitingEvent = addEvent(function()
		local s = ExpeditionManager.getSessionByKey(key)
		if s and s.state == "waiting" and not huntEnded(s) then
			ExpeditionWaves.spawn(s)
		end
	end, delay)
	ExpeditionManager.broadcastStatus(session)
end

--- Despawn remaining wave monsters and start a fresh wave (unreachable-spawn unstuck).
function ExpeditionWaves.scheduleDespawn(session)
	if not session then
		return
	end
	clearDespawn(session)
	local key = session.key
	local ms = ExpeditionConfig.huntDespawnMs and ExpeditionConfig.huntDespawnMs() or ExpeditionConfig.HUNT_DESPAWN_MS
	session.despawnEvent = addEvent(function()
		local s = ExpeditionManager.getSessionByKey(key)
		if not s or s.state ~= "hunting" then
			return
		end
		s.despawnEvent = nil
		-- Drop ownership before remove so death handlers do not double-count / re-schedule.
		for mid, ownerKey in pairs(monsterOwners) do
			if ownerKey == key then
				monsterOwners[mid] = nil
				local monster = Monster(mid)
				if monster then
					monster:remove()
				end
			end
		end
		s.alive = 0
		scheduleNextWave(s)
	end, ms)
end

function ExpeditionWaves.spawn(session)
	if huntEnded(session) then
		return
	end
	if not session or not session.instance or not session.catalog then
		return
	end
	-- Soul Pit drives its own wave table.
	if session.kind == "soulpit" or (session.catalog and session.catalog.id == "soul-pit") then
		return
	end

	clearWaiting(session)
	clearRelocate(session)
	clearDespawn(session)

	beginSpawnOnceSettled(session)
end

function ExpeditionWaves.onMonsterDeath(creature, corpse)
	if not creature then
		return
	end
	-- Boss fights own their monsters separately.
	if ExpeditionBoss and ExpeditionBoss.onMonsterDeath and ExpeditionBoss.onMonsterDeath(creature, corpse) then
		return
	end
	local monsterId = creature:getId()
	local key = monsterOwners[monsterId]
	monsterOwners[monsterId] = nil
	if not key then
		return
	end
	local session = ExpeditionManager.getSessionByKey(key)
	if not session then
		return
	end
	if session.state == "ended" then
		return
	end

	session.alive = math.max(0, (session.alive or 1) - 1)
	session.kills = (session.kills or 0) + 1
	ExpeditionManager.broadcastStatus(session)

	if session.alive <= 0 and session.state == "hunting" then
		clearDespawn(session)
		scheduleNextWave(session)
	end
end

function ExpeditionWaves.clear(session)
	if not session then
		return
	end
	clearWaiting(session)
	clearRelocate(session)
	clearDespawn(session)
	if session.instance and session.instance.zone then
		session.instance.zone:removeMonsters()
	end
	-- Hunt instances often have no Zone; drop live monsters by ownership (same as despawn).
	for mid, key in pairs(monsterOwners) do
		if key == session.key then
			monsterOwners[mid] = nil
			local monster = Monster(mid)
			if monster then
				monster:remove()
			end
		end
	end
	session.alive = 0
end
