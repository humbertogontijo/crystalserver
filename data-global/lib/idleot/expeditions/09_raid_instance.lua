-- Shared raid instances: redirect Canary Lua Raid scripts into expedition slots.
-- Raid definition scripts under scripts/raids/** stay unchanged (A2).

RaidInstance = RaidInstance or {}
RaidInstance.active = RaidInstance.active or {}

local function displayName(raidName)
	if type(raidName) ~= "string" or raidName == "" then
		return "Raid"
	end
	local pretty = raidName:gsub("[%.%-_]", " ")
	return pretty:gsub("(%a)([%w]*)", function(first, rest)
		return first:upper() .. rest
	end)
end

local function zoneAABB(zone)
	if not zone then
		return nil
	end
	local positions = zone:getPositions()
	if type(positions) ~= "table" or #positions == 0 then
		return nil
	end
	local minX, minY, maxX, maxY = positions[1].x, positions[1].y, positions[1].x, positions[1].y
	local z = positions[1].z
	for _, pos in ipairs(positions) do
		if pos.x < minX then
			minX = pos.x
		end
		if pos.y < minY then
			minY = pos.y
		end
		if pos.x > maxX then
			maxX = pos.x
		end
		if pos.y > maxY then
			maxY = pos.y
		end
	end
	return { minX = minX, minY = minY, maxX = maxX, maxY = maxY, z = z }
end

local RAID_MIN_HALF_EXTENT = 8

--- Instance fence {x, y, w, h}: the raid's world area (XML spawn rectangles / Lua zones),
--- never smaller than a 17x17 box around the arena center.
local function raidBoundary(raid, center)
	local minX, maxX = center.x - RAID_MIN_HALF_EXTENT, center.x + RAID_MIN_HALF_EXTENT
	local minY, maxY = center.y - RAID_MIN_HALF_EXTENT, center.y + RAID_MIN_HALF_EXTENT
	local function extend(area)
		if type(area) ~= "table" or not area.minX then
			return
		end
		minX = math.min(minX, area.minX)
		maxX = math.max(maxX, area.maxX)
		minY = math.min(minY, area.minY)
		maxY = math.max(maxY, area.maxY)
	end
	extend(raid._raidSpawnArea)
	if raid.zone then
		extend(zoneAABB(Zone(raid.zone)))
	end
	if raid.spawnZone and raid.spawnZone ~= raid.zone then
		extend(zoneAABB(Zone(raid.spawnZone)))
	end
	return { x = minX, y = minY, z = center.z, w = maxX - minX + 1, h = maxY - minY + 1 }
end

local function isRaidEncounter(encounter)
	return encounter and Raid and Raid.registry and Raid.registry[encounter.name] == encounter
end

function RaidInstance.hasInstance(encounter)
	return encounter and encounter._raidInstance ~= nil
end

function RaidInstance.getActive(raidName)
	return RaidInstance.active[raidName]
end

function RaidInstance.listActive()
	local out = {}
	for name, session in pairs(RaidInstance.active) do
		-- Cleared (loot grace) and tearing-down raids are not listed / joinable.
		if session and not session.tearingDown and not session.graceStarted then
			local levels = ExpeditionConfig.RaidLevels[name]
			local levelMin = levels and levels.levelMin or nil
			local recommendedLevel = levels and levels.recommendedLevel or nil
			local creatureId = session.bossRaceId
			if (not creatureId or creatureId <= 0) and levels then
				creatureId = levels.creatureId
			end
			out[#out + 1] = {
				name = name,
				displayName = session.displayName or displayName(name),
				startedAt = session.startedAt or 0,
				players = #(session.playerIds or {}),
				joinable = true,
				role = session.role or ExpeditionConfig.raidRole(name),
				creatureId = type(creatureId) == "number" and creatureId > 0 and creatureId or nil,
				-- Advisory only - join is never gated by level. Client may warn.
				levelMin = type(levelMin) == "number" and levelMin or nil,
				recommendedLevel = type(recommendedLevel) == "number" and recommendedLevel or nil,
			}
		end
	end
	table.sort(out, function(a, b)
		local levelsA = ExpeditionConfig.RaidLevels[a.name]
		local levelsB = ExpeditionConfig.RaidLevels[b.name]
		local cpA = tonumber(levelsA and levelsA.combatPower) or 0
		local cpB = tonumber(levelsB and levelsB.combatPower) or 0
		if cpA ~= cpB then
			return cpA < cpB
		end
		return tostring(a.displayName or a.name) < tostring(b.displayName or b.name)
	end)
	return out
end

function RaidInstance.broadcastActiveRaids()
	local payload = {
		type = "activeRaids",
		activeRaids = RaidInstance.listActive(),
	}
	for _, player in ipairs(Game.getPlayers()) do
		ExpeditionProtocol.send(player, payload)
	end
end

function RaidInstance.sendActiveRaids(player)
	if not player then
		return false
	end
	return ExpeditionProtocol.send(player, {
		type = "activeRaids",
		activeRaids = RaidInstance.listActive(),
	})
end

local function isGroundWalkable(pos, instanceId)
	local tile = Tile(pos)
	if not tile or not tile:getGround() then
		return false
	end
	if instanceId then
		return not tile:hasProperty(CONST_PROP_BLOCKSOLID, instanceId)
	end
	return not tile:hasFlag(TILESTATE_BLOCKSOLID)
end

local function raidSpawnReserved(raid)
	if not raid then
		return nil
	end
	if not raid._raidSpawnReserved then
		raid._raidSpawnReserved = {}
	end
	return raid._raidSpawnReserved
end

local function claimRaidSpawn(raid, pos)
	if pos then
		ExpeditionInstance.reservePos(raidSpawnReserved(raid), pos)
	end
	return pos
end

--- Keep raid scripts on real world coordinates; isolation is instanceId.
local function remapPosition(raid, pos)
	local instance = raid._raidInstance
	if not instance or not pos then
		return pos
	end
	local reserved = raidSpawnReserved(raid)
	local mapped = Position(pos.x, pos.y, pos.z)
	local mappedKey = CombatGeo.posKey(mapped)
	local resolved = mapped
	if not isGroundWalkable(mapped, instance.instanceId) or (reserved and reserved[mappedKey]) then
		resolved = ExpeditionInstance.randomWalkable(instance, instance.entry, reserved)
	elseif CombatGeo.sameTile(mapped, instance.entry) then
		resolved = ExpeditionInstance.randomAttackRangeWalkable(instance, instance.entry, 1, reserved)
			or ExpeditionInstance.randomWalkable(instance, instance.entry, reserved)
	end
	return claimRaidSpawn(raid, resolved or mapped)
end

local function resolveRaidSpawnPosition(raid, preferred, area)
	local instance = raid._raidInstance
	local reserved = raidSpawnReserved(raid)
	local preferredKey = preferred and CombatGeo.posKey(preferred)
	if
		preferred
		and isGroundWalkable(preferred, instance and instance.instanceId)
		and not CombatGeo.sameTile(preferred, instance and instance.entry)
		and not (reserved and preferredKey and reserved[preferredKey])
	then
		return claimRaidSpawn(raid, preferred)
	end
	if not instance then
		return preferred
	end
	local resolved = ExpeditionInstance.randomWalkable(instance, instance.entry, reserved, area)
		or ExpeditionInstance.randomAttackRangeWalkable(instance, instance.entry, 1, reserved)
		or preferred
	return claimRaidSpawn(raid, resolved)
end

function RaidInstance.provision(raid)
	if not raid or not isRaidEncounter(raid) then
		return false
	end
	if RaidInstance.active[raid.name] then
		logger.warn("[RaidInstance] raid {} already has an active instance", raid.name)
		return false
	end

	local worldZoneName = raid.zone
	local worldSpawnZoneName = raid.spawnZone or raid.zone

	local kind = ExpeditionConfig.RAID_ARENA_KIND or "raid"
	local region = ExpeditionConfig.raidRegionId(raid.name)
	local center = region and ExpeditionConfig.RaidArenaCenters[region] or nil
	if not center and raid._raidSpawnCenter and raid._raidSpawnCenter.x then
		center = raid._raidSpawnCenter
	end
	if not center then
		local aabb = zoneAABB(Zone(worldZoneName))
		if aabb then
			center = {
				x = math.floor((aabb.minX + aabb.maxX) / 2),
				y = math.floor((aabb.minY + aabb.maxY) / 2),
				z = aabb.z,
			}
			logger.warn(
				"[RaidInstance] no RaidArenaCenters for {}; using zone midpoint {},{},{}",
				raid.name,
				center.x,
				center.y,
				center.z
			)
		else
			logger.error("[RaidInstance] no center for raid {}", raid.name)
			return false
		end
	end

	local instanceId = ExpeditionInstance.allocate("raid", InstanceWorld.subareaIdAt(center), string.format("%s_%d", raid.name, os.time()), raid.name)
	if instanceId == nil then
		logger.error("[RaidInstance] no expedition instances for raid {}", raid.name)
		return false
	end

	local buildOpts = {
		id = region,
		region = region,
		kind = kind,
		center = center,
		boundary = raidBoundary(raid, center),
	}
	-- XML raids may span multiple floors; keep all spawn zs so falling/stairs
	-- do not trip reconcilePresence ("You left the raid area.").
	if type(raid._raidSpawnFloors) == "table" and #raid._raidSpawnFloors > 0 then
		buildOpts.floors = raid._raidSpawnFloors
	end
	local instance, err = ExpeditionInstance.build(instanceId, buildOpts, os.time())
	if not instance then
		ExpeditionInstance.free(instanceId)
		logger.error("[RaidInstance] failed to build arena for {}: {}", raid.name, err or "unknown")
		return false
	end

	local aabb = zoneAABB(Zone(worldZoneName))

	raid._raidWorldZone = worldZoneName
	raid._raidWorldSpawnZone = worldSpawnZoneName
	raid._raidWorldAABB = aabb
	raid._raidInstance = instance
	raid._raidArenaKind = kind
	raid._raidArenaRegion = region
	raid._raidSpawnReserved = {}
	-- Keep world zones so raid scripts spawn at real coordinates.

	local levels = ExpeditionConfig.RaidLevels[raid.name]
	local seedRaceId = levels and tonumber(levels.creatureId) or nil
	if seedRaceId and seedRaceId <= 0 then
		seedRaceId = nil
	end

	local session = {
		raid = raid,
		raidName = raid.name,
		displayName = displayName(raid.name),
		role = ExpeditionConfig.raidRole(raid.name),
		-- Race id of the showcase creature; seeded from catalog, refined on spawn.
		bossRaceId = seedRaceId,
		-- Runtime creature id for AI focus (not race id).
		bossCreatureId = nil,
		instance = instance,
		playerIds = {},
		memberKeys = {},
		startedAt = os.time(),
		lastStageStarted = false,
		spawnedOnce = false,
		-- True once createMonster succeeds at least once; loot grace must not start before this.
		monstersSpawned = false,
		clearEligibleAt = nil,
		graceStarted = false,
		tearingDown = false,
	}
	session.scope = Scope.new({
		name = "raid:" .. raid.name,
		instanceId = instanceId,
		alive = function()
			return RaidInstance.active[raid.name] == session and not session.tearingDown
		end,
	})
	RaidInstance.active[raid.name] = session
	RaidInstance.scheduleDespawn(session)

	logger.info("[RaidInstance] provisioned shared instance for {} id={}", raid.name, instanceId)
	return true
end

local function restoreRaidZones(raid)
	if not raid then
		return
	end
	if raid._raidWorldZone then
		raid.zone = raid._raidWorldZone
	end
	if raid._raidWorldSpawnZone then
		raid.spawnZone = raid._raidWorldSpawnZone
	end
	raid._raidInstance = nil
	raid._raidWorldAABB = nil
	raid._raidWorldZone = nil
	raid._raidWorldSpawnZone = nil
	raid._raidSpawnReserved = nil
end

--- Raid interval safety timeout (raids.xml interval2 / Lua minGapBetween).
function RaidInstance.scheduleDespawn(session)
	if not session or session.tearingDown then
		return
	end
	local raidName = session.raidName
	local ms = ExpeditionConfig.raidDespawnMs(raidName, session.raid)
	session.scope:timer("despawn", ms, function()
		if session.graceStarted then
			return
		end
		logger.info("[RaidInstance] despawn timeout for {} ({} ms)", raidName, ms)
		for _, id in ipairs(session.playerIds or {}) do
			local player = Player(id)
			if player then
				player:sendTextMessage(MESSAGE_EVENT_ADVANCE, "The raid timed out.")
			end
		end
		RaidInstance.teardown(raidName, { silent = true })
	end)
end

function RaidInstance.teardown(raidName, opts)
	opts = opts or {}
	local session = RaidInstance.active[raidName]
	if not session then
		return
	end
	if session.tearingDown and not opts.force then
		return
	end
	session.tearingDown = true
	session.scope:dispose()

	local raid = session.raid
	local playerIds = {}
	for _, id in ipairs(session.playerIds or {}) do
		playerIds[#playerIds + 1] = id
	end

	for _, id in ipairs(playerIds) do
		local player = Player(id)
		local memberSession = player and ExpeditionManager.getSessionByPlayer(player) or nil
		if memberSession and memberSession.kind == "raid" then
			ExpeditionAI.stop(memberSession)
			ExpeditionManager.unbindSession(memberSession)
		end
		if player then
			player:unregisterEvent("ExpeditionPlayerDeath")
			ExpeditionManager.clearActiveFlag(player)
			local returnPos = ExpeditionManager.loadReturnPos(player)
			if player:getHealth() > 0 then
				InstanceWorld.exitToOpenWorld(player, returnPos)
				local now = player:getPosition()
				if now then
					now:sendMagicEffect(CONST_ME_TELEPORT)
				end
			end
			ExpeditionProtocol.sendEnded(player)
			if not opts.silent then
				player:sendTextMessage(MESSAGE_EVENT_ADVANCE, "The raid has ended.")
			end
		end
	end

	ExpeditionInstance.teardown(session.instance)
	restoreRaidZones(raid)

	if raid and raid.currentStage ~= Encounter.unstarted then
		-- Abort stage machine without re-entering provision.
		raid:cancelEvents()
		raid.currentStage = Encounter.unstarted
	end

	RaidInstance.active[raidName] = nil
	RaidInstance.broadcastActiveRaids()
	logger.info("[RaidInstance] tore down raid {}", raidName)
end

function RaidInstance.onEnterStage(raid, stageNumber)
	local session = RaidInstance.active[raid.name]
	if not session then
		return
	end
	if stageNumber == #raid.stages then
		session.lastStageStarted = true
		-- Wait for spawn flash + a buffer before allowing "all clear".
		local spawnMs = tonumber(raid and raid.timeToSpawnMonsters) or 0
		local baseMs = ExpeditionConfig.RAID_CLEAR_ELIGIBLE_DELAY_MS or 5000
		local delayMs = math.max(baseMs, spawnMs + 2000)
		session.clearEligibleAt = os.time() + math.ceil(delayMs / 1000)
		session.scope:timer("clearEligible", math.ceil(delayMs / 1000) * 1000, function()
			RaidInstance.watchTick(session)
		end)
		logger.info("[RaidInstance] last stage started for {}", raid.name)
	end
	RaidInstance.refreshMemberStatus(session)
end

function RaidInstance.markSpawned(raid)
	local session = RaidInstance.active[raid.name]
	if session then
		session.spawnedOnce = true
	end
end

--- Prefer a single last-stage spawn as the raid boss for AI focus (identity by race id).
function RaidInstance.markBoss(raid, monster, _monsterName)
	local session = RaidInstance.active[raid and raid.name]
	if not session or not monster then
		return
	end
	session.bossCreatureId = monster:getId()
	local raceId = ExpeditionConfig.creatureIdFromMonster(monster)
	if raceId and session.bossRaceId ~= raceId then
		session.bossRaceId = raceId
		RaidInstance.broadcastActiveRaids()
	elseif raceId then
		session.bossRaceId = raceId
	end
end

function RaidInstance.getBoss(raidName)
	local session = RaidInstance.active[raidName]
	if not session then
		return nil
	end
	if session.bossCreatureId then
		local boss = Monster(session.bossCreatureId)
		if boss and boss:getHealth() > 0 then
			return boss
		end
		session.bossCreatureId = nil
	end
	local wantRace = session.bossRaceId
	if wantRace and wantRace > 0 and session.instance and session.instance.instanceId then
		for _, monster in ipairs(Game.getInstanceMonsters(session.instance.instanceId)) do
			if monster:getHealth() > 0 then
				local raceId = ExpeditionConfig.creatureIdFromMonster(monster)
				if raceId == wantRace then
					session.bossCreatureId = monster:getId()
					return monster
				end
			end
		end
	end
	return nil
end

function RaidInstance.countAlive(session)
	if not session then
		return 0
	end
	local instanceId = session.instance and session.instance.instanceId
	if instanceId then
		local n = 0
		for _, monster in ipairs(Game.getInstanceMonsters(instanceId)) do
			if monster:getHealth() > 0 then
				n = n + 1
			end
		end
		return n
	end
	if session.raid and session.raid.countMonsters then
		return session.raid:countMonsters()
	end
	return 0
end

function RaidInstance.activeCount()
	local n = 0
	for _, session in pairs(RaidInstance.active) do
		if session and not session.tearingDown then
			n = n + 1
		end
	end
	return n
end

function RaidInstance.refreshMemberStatus(session, alive)
	if not session then
		return
	end
	alive = alive or RaidInstance.countAlive(session)
	for _, id in ipairs(session.playerIds or {}) do
		local player = Player(id)
		local member = ExpeditionManager.getSessionByPlayer(player)
		if member and member.kind == "raid" then
			member.alive = alive
			member.wave = session.raid and session.raid.currentStage or 0
			member.state = session.graceStarted and "waiting" or "hunting"
			member.role = session.role or member.role
			member.bossRaceId = session.bossRaceId
			if member.catalog then
				member.catalog.role = member.role
				member.catalog.creatureId = session.bossRaceId or member.catalog.creatureId
			end
			ExpeditionProtocol.sendStatus(player, member)
		end
	end
end

local function beginGrace(session)
	if not session or session.graceStarted or session.tearingDown then
		return
	end
	session.graceStarted = true
	local graceMs = ExpeditionConfig.LOOT_GRACE_MS or 5000
	logger.info("[RaidInstance] loot grace started for {} ({} ms)", session.raidName, graceMs)
	for _, id in ipairs(session.playerIds or {}) do
		local player = Player(id)
		if player then
			player:sendTextMessage(
				MESSAGE_EVENT_ADVANCE,
				string.format("Raid cleared! Loot window: %d seconds.", math.floor(graceMs / 1000))
			)
		end
	end
	RaidInstance.broadcastActiveRaids()
	local raidName = session.raidName
	local function finish()
		if RaidInstance.active[raidName] == session then
			RaidInstance.teardown(raidName)
		end
	end
	-- The loot window is the exit channel.
	local channeled = InstanceTeleport
		and InstanceTeleport.requestExpeditionExit
		and InstanceTeleport.requestExpeditionExit({
			memberIds = session.playerIds,
			destination = InstanceTeleport.DEST_OPEN_WORLD,
			durationMs = graceMs,
			onComplete = finish,
		})
	if not channeled then
		session.scope:timer("grace", graceMs, finish)
	end
end

--- Recount, push the count to members and start the loot grace once the last stage is
--- cleared. Runs on spawns and removals (requestCount) and when the clear gate opens.
function RaidInstance.watchTick(session)
	if not session or session.tearingDown or session.graceStarted or not session.raid then
		return
	end
	local monsters = RaidInstance.countAlive(session)
	if monsters > 0 then
		session.monstersSpawned = true
	end
	RaidInstance.refreshMemberStatus(session, monsters)
	-- Do not treat "never spawned" as cleared — despawn timeout owns that case.
	if monsters > 0 or not session.monstersSpawned or not session.lastStageStarted then
		return
	end
	if session.clearEligibleAt and os.time() < session.clearEligibleAt then
		return
	end
	beginGrace(session)
end

--- Coalesce a recount into the next tick (a burst of deaths counts once).
function RaidInstance.requestCount(session)
	session.scope:timer("count", 0, function()
		RaidInstance.watchTick(session)
	end)
end

local function sessionOfInstance(instanceId)
	local key = Instance.normalize(instanceId)
	for _, session in pairs(RaidInstance.active) do
		if session.instance and session.instance.instanceId == key then
			return session
		end
	end
	return nil
end

-- Deaths, despawns and timeLimit removals alike.
IdleEvents.on("monster.removed", function(monster)
	local session = sessionOfInstance(monster:getInstanceId())
	if session then
		RaidInstance.requestCount(session)
	end
end, "RaidInstance")

function RaidInstance.onStarted(raid)
	local session = RaidInstance.active[raid.name]
	if not session then
		return
	end
	local hint = ExpeditionConfig.RAID_JOIN_HINT or "Join via Expeditions > Raids."
	local entry = nil
	for _, raidEntry in ipairs(RaidInstance.listActive()) do
		if raidEntry.name == raid.name then
			entry = raidEntry
			break
		end
	end
	local text = string.format("Raid available: %s. %s", session.displayName, hint)
	for _, player in ipairs(Game.getPlayers()) do
		-- Client shows the raid banner; keep the text out of the center screen.
		player:sendTextMessage(MESSAGE_STATUS, text)
		if entry then
			ExpeditionProtocol.send(player, { type = "raidStarted", raid = entry })
		end
	end
	RaidInstance.broadcastActiveRaids()
end

local function saveReturn(player)
	ExpeditionManager.saveReturnPos(player)
end

function RaidInstance.join(player, raidName, loadout, options)
	if not player then
		return
	end
	if not ExpeditionSafety.hasStamina(player) then
		ExpeditionProtocol.sendError(player, "You need stamina to enter an expedition.")
		return
	end
	if PzTeleport.isCombatLocked(player)
		and not PzTeleport.isGod(player)
	then
		ExpeditionProtocol.sendError(player, PzTeleport.PZ_LOCKED_MESSAGE or "You cannot teleport while PZ-locked.")
		return
	end
	if ExpeditionManager.getSessionByPlayer(player) then
		ExpeditionProtocol.sendError(player, "Already on an expedition.")
		return
	end
	local session = RaidInstance.active[raidName]
	if not session or session.tearingDown then
		ExpeditionProtocol.sendError(player, "That raid is not active.")
		return
	end
	if session.graceStarted then
		ExpeditionProtocol.sendError(player, "That raid has already been cleared.")
		return
	end
	if not session.instance or not session.instance.entry then
		ExpeditionProtocol.sendError(player, "Raid instance is not ready.")
		return
	end

	saveReturn(player)
	ExpeditionManager.markActiveFlag(player, raidName)
	SampleSpells.ensure(player)

	local automation = ExpeditionManager.sanitizeAutomation(loadout, player)
	if #(automation.slots or {}) == 0 then
		automation = ExpeditionManager.loadPersistedAutomation(player)
	else
		ExpeditionManager.persistAutomation(player, automation)
	end
	local stopOpts = ExpeditionConfig.normalizeStopOptions(options)
	local contentRole = session.role or ExpeditionConfig.raidRole(raidName)
	local raceId = session.bossRaceId
		or (ExpeditionConfig.RaidLevels[raidName] and ExpeditionConfig.RaidLevels[raidName].creatureId)
		or nil
	-- MonsterType / boss cooldown need the real monster name ("The Evil Eye"),
	-- not the raid display label ("Abdendriel Theevileye"). raceId alone is enough
	-- when CreatureInfo indexes that id (fallbackName intentionally omitted).
	local bossName = nil
	if raceId then
		bossName = ExpeditionConfig.monsterNameByCreatureId(raceId)
	end
	local key = "raid:" .. raidName .. ":p" .. player:getGuid()
	local member = {
		key = key,
		playerId = player:getId(),
		guid = player:getGuid(),
		playerIds = session.playerIds,
		kind = "raid",
		raidName = raidName,
		role = contentRole,
		stance = contentRole == "boss" and CombatAutomationConfig.stanceForPlayer(player) or nil,
		bossRaceId = session.bossRaceId,
		catalog = {
			id = raidName,
			name = bossName or session.displayName,
			kind = "raid",
			role = contentRole,
			creatureId = raceId,
		},
		instance = session.instance,
		wave = session.raid and session.raid.currentStage or 0,
		alive = RaidInstance.countAlive(session),
		kills = 0,
		state = "hunting",
		startedAt = session.startedAt,
		automation = automation,
		stopOnInsufficientGold = stopOpts.stopOnInsufficientGold,
		stopOnInsufficientCap = stopOpts.stopOnInsufficientCap,
	}

	session.playerIds[#session.playerIds + 1] = player:getId()
	session.memberKeys[player:getId()] = key
	ExpeditionManager.bindSession(member)
	ExpeditionConfig.pickAnchor(member)

	player:registerEvent("ExpeditionPlayerDeath")
	ExpeditionAI.enablePersistence(player)

	local function finishRaidEnter(p)
		local s = RaidInstance.active[raidName]
		local bound = ExpeditionManager.getSessionByKey(key)
		if not s or not p or not bound then
			return
		end
		local instance = s.instance
		if not instance or not instance.entry then
			RaidInstance.leave(p, { silent = true })
			ExpeditionProtocol.sendError(p, "Raid instance is not ready.")
			return
		end
		p:setFollowCreature(nil)
		local entry = instance.entry
		if entry and not isGroundWalkable(entry, instance.instanceId) then
			entry = resolveRaidSpawnPosition(s.raid, entry) or entry
			if entry then
				instance.entry = entry
			end
		end
		local entered = InstanceWorld.enterInstance(p, instance.instanceId, entry)
		if not entered then
			logger.error(
				"[RaidInstance] enterInstance failed for {} into {} at {},{},{}",
				p:getName(),
				raidName,
				entry and entry.x or 0,
				entry and entry.y or 0,
				entry and entry.z or 0
			)
			RaidInstance.leave(p, { silent = true })
			ExpeditionProtocol.sendError(p, "Could not enter the raid arena.")
			return
		end
		local pos = p:getPosition()
		if
			not pos
			or (p:getInstanceId() ~= instance.instanceId)
			or not ExpeditionInstance.contains(instance, pos)
		then
			logger.error(
				"[RaidInstance] {} landed outside raid {} at {},{},{} (instance={})",
				p:getName(),
				raidName,
				pos and pos.x or 0,
				pos and pos.y or 0,
				pos and pos.z or 0,
				instance.instanceId or 0
			)
			RaidInstance.leave(p, { silent = true })
			ExpeditionProtocol.sendError(p, "Could not enter the raid arena.")
			return
		end
		Game.runInInstance(instance.instanceId, function()
			pos:sendMagicEffect(CONST_ME_TELEPORT)
		end)
		ExpeditionManager.markEntered(bound)
		p:sendTextMessage(
			MESSAGE_EVENT_ADVANCE,
			string.format("Joined raid: %s (stance: %s)", s.displayName or raidName, bound.role or "melee")
		)
		ExpeditionProtocol.sendStatus(p, bound)
		local sessionKey = key
		local playerId = member.playerId
		addEvent(function()
			local live = ExpeditionManager.getSessionByKey(sessionKey)
			local joined = live and Player(playerId)
			if not live or not joined then
				return
			end
			local landed = joined:getPosition()
			if landed then
				joined:sendMapDescription(landed)
			end
			ExpeditionAI.start(live)
			RaidInstance.broadcastActiveRaids()
		end, ExpeditionConfig.ENTRY_CLIENT_SYNC_MS or 500)
	end

	local ok, err = InstanceTeleport.armSoloExpedition(player, {
		onComplete = finishRaidEnter,
		onCancel = function(p)
			if p then
				RaidInstance.leave(p, { silent = true })
			end
		end,
	})
	if not ok then
		ExpeditionProtocol.sendError(player, err or "Could not start raid teleport.")
		RaidInstance.leave(player, { silent = true })
		return
	end
	ExpeditionProtocol.sendStatus(player, member)
end

local function removePlayerId(list, playerId)
	if type(list) ~= "table" then
		return
	end
	for i = #list, 1, -1 do
		if list[i] == playerId then
			table.remove(list, i)
		end
	end
end

function RaidInstance.leave(player, opts)
	opts = opts or {}
	if not player then
		return
	end
	local member = ExpeditionManager.getSessionByPlayer(player)
	if not member or member.kind ~= "raid" then
		-- Idempotent recovery when the shared raid died with the process.
		ExpeditionManager.clearActiveFlag(player)
		ExpeditionProtocol.sendEnded(player)
		return
	end
	local raidName = member.raidName
	local session = RaidInstance.active[raidName]
	local playerId = player:getId()

	ExpeditionAI.stop(member)
	ExpeditionManager.unbindSession(member)
	player:unregisterEvent("ExpeditionPlayerDeath")
	ExpeditionManager.clearActiveFlag(player)

	if session then
		removePlayerId(session.playerIds, playerId)
		if session.memberKeys then
			session.memberKeys[playerId] = nil
		end
	end

	local returnPos = ExpeditionManager.loadReturnPos(player)
	ExpeditionManager.clearAreaEffects(player)
	if player:getHealth() > 0 then
		local wentHometown = false
		if opts.goHometown then
			wentHometown = InstanceTeleport.executeHometown(player, { fromExpedition = true }) and true or false
		end
		if not wentHometown then
			InstanceWorld.exitToOpenWorld(player, returnPos)
		end
		local now = player:getPosition()
		if now then
			now:sendMagicEffect(CONST_ME_TELEPORT)
		end
	end
	ExpeditionProtocol.sendEnded(player)
	if not opts.silent then
		player:sendTextMessage(
			MESSAGE_EVENT_ADVANCE,
			opts.goHometown and "You recalled to your hometown." or "You left the raid."
		)
	end
	RaidInstance.broadcastActiveRaids()
	-- Shared instance keeps running with zero players (late join still allowed).
end

function RaidInstance.onPlayerDeath(player)
	if not player then
		return
	end
	local member = ExpeditionManager.getSessionByPlayer(player)
	if not member or member.kind ~= "raid" then
		return
	end
	-- End this player's raid run; keep the shared instance for others / late joiners.
	RaidInstance.leave(player, { silent = true })
end

-- Raid / Encounter (data/libs) are recreated on every core reload, before the product libs.
do
	function Raid:tryStart(force)
		if not force and not self:canStart() then
			return false
		end
		-- /simraid only rolls chance math; it must not open an instance or run stages.
		if self.name == "simraid" then
			self.kv:set("last-occurrence", os.time())
			return true
		end
		local maxConcurrent = ExpeditionConfig.RAID_MAX_CONCURRENT or 2
		if RaidInstance.activeCount() >= maxConcurrent then
			if force then
				logger.warn("[RaidInstance] at concurrent cap ({}); skip {}", maxConcurrent, self.name)
			end
			return false
		end
		if not RaidInstance.provision(self) then
			logger.error("[RaidInstance] provision failed for {}", self.name)
			return false
		end
		logger.info("Starting raid {}", self.name)
		self.kv:set("last-occurrence", os.time())
		local started = self:start()
		if not started then
			RaidInstance.teardown(self.name, { force = true, silent = true })
			return false
		end
		RaidInstance.onStarted(self)
		return true
	end

	local originalReset = Encounter.reset
	function Encounter:reset()
		if isRaidEncounter(self) and RaidInstance.hasInstance(self) then
			RaidInstance.teardown(self.name, { silent = true })
			return true
		end
		return originalReset(self)
	end

	IdleEvents.on("encounter.stage", function(encounter, stageNumber)
		if isRaidEncounter(encounter) and RaidInstance.hasInstance(encounter) then
			RaidInstance.onEnterStage(encounter, stageNumber)
		end
	end, "RaidInstance")

	local originalNextStage = Encounter.nextStage
	function Encounter:nextStage()
		if isRaidEncounter(self) and RaidInstance.hasInstance(self) then
			if self.currentStage == #self.stages then
				-- Trailing autoAdvance must not reset/teardown; watcher owns the end.
				RaidInstance.onEnterStage(self, self.currentStage)
				return true
			end
		end
		return originalNextStage(self)
	end

	local originalSpawnMonsters = Encounter.spawnMonsters
	function Encounter:spawnMonsters(config)
		if not (isRaidEncounter(self) and RaidInstance.hasInstance(self)) then
			return originalSpawnMonsters(self, config)
		end

		RaidInstance.markSpawned(self)
		local instance = self._raidInstance
		local positions = config.positions
		local amount = config.amount
		if positions and config.position then
			error("You can't use both 'position' and 'positions' in the same config.")
		end
		if positions and amount then
			error("You can't use both 'amount' and 'positions' in the same config.")
		end
		if amount and amount > 0 then
			positions = {}
			for _ = 1, amount do
				if config.position then
					table.insert(positions, remapPosition(self, config.position))
				else
					-- Prefer instance walkables. Zone:randomPosition → Tile:isWalkable(..., proj)
					-- can nil-crash on getItems() for stamped/border tiles; never insert nil.
					table.insert(positions, resolveRaidSpawnPosition(self, nil, config.area))
				end
			end
		elseif positions then
			local remapped = {}
			for _, pos in ipairs(positions) do
				remapped[#remapped + 1] = remapPosition(self, pos)
			end
			positions = remapped
		elseif config.position then
			positions = { remapPosition(self, config.position) }
		else
			positions = {}
		end

		-- Last-stage single spawn ≈ raid boss (boss-role raids only).
		local raidSession = RaidInstance.active[self.name]
		local raidRole = raidSession and raidSession.role or ExpeditionConfig.raidRole(self.name)
		local markAsBoss = raidRole == "boss" and self.currentStage == #self.stages and #positions == 1
		local raidName = self.name
		-- Spawns fire later: bind them to this run's instance, never to whatever runs then.
		local scheduledInstance = self._raidInstance
		local scheduledKey = scheduledInstance and scheduledInstance.instanceId or nil

		for _, position in ipairs(positions) do
			if position then
				if self.timeToSpawnMonsters >= 1000 then
					for i = 1, self.timeToSpawnMonsters / 1000 do
						self:addEvent(function(flashPos)
							Game.runInInstance(scheduledKey, function()
								flashPos:sendMagicEffect(CONST_ME_TELEPORT)
							end)
						end, i * 1000, position)
					end
				end
				local name = config.name
				if type(name) == "table" then
					name = name[math.random(#name)]
				end
				self:addEvent(function(monsterName, spawnPos, event, spawn, timeLimit, asBoss)
					if not spawnPos or not spawnPos.x then
						return false
					end
					-- Re-materialize Position (addEvent registry can leave a plain table).
					spawnPos = Position(spawnPos.x, spawnPos.y, spawnPos.z)
					local raid = Raid.registry[raidName]
					local inst = scheduledInstance
					if not scheduledKey or not Instance.isLive(scheduledKey) or not raid or raid._raidInstance ~= inst then
						return false
					end
					-- Re-check entry avoidance at spawn time (map may have loaded since schedule).
					if CombatGeo.sameTile(spawnPos, inst.entry) then
						spawnPos = resolveRaidSpawnPosition(raid, nil) or spawnPos
					end
					local monster = nil
					monster = ExpeditionInstance.createMonsterExclusive(monsterName, spawnPos, inst)
					if not monster then
						monster = Game.createMonster(monsterName, spawnPos, true, true, nil, scheduledKey)
						if monster then
							InstanceWorld.applyOpenWorldForge(monster)
						end
					end
					if not monster then
						logger.warn(
							"[RaidInstance] spawn failed for {} at {},{},{} (instance={})",
							monsterName,
							spawnPos.x,
							spawnPos.y,
							spawnPos.z,
							inst and inst.instanceId or 0
						)
						return false
					end
					-- Extended/forced placement may step past the fence where nobody can reach it.
					local placed = monster:getPosition()
					if not ExpeditionInstance.contains(inst, placed) then
						logger.warn(
							"[RaidInstance] {} landed outside raid fence at {},{},{} (instance={})",
							monsterName,
							placed.x,
							placed.y,
							placed.z,
							inst.instanceId or 0
						)
						monster:setDropLoot(false)
						monster:remove()
						return false
					end
					monster:setRewardBoss()
					monster:registerEvent("IdleMonsterDeath")
					local session = RaidInstance.active[raidName]
					if session then
						session.monstersSpawned = true
						RaidInstance.requestCount(session)
					end
					if asBoss then
						RaidInstance.markBoss(raid, monster, monsterName)
					end
					if spawn then
						spawn(monster)
					end
					if event then
						local events = event
						if type(events) == "string" then
							events = { events }
						end
						for _, eventName in ipairs(events) do
							monster:registerEvent(eventName)
						end
					end
					if timeLimit then
						self:addEvent(function(monsterId)
							local m = Monster(monsterId)
							if m then
								m:remove()
							end
						end, timeLimit, monster:getID())
					end
				end, self.timeToSpawnMonsters, name, position, config.event, config.spawn, config.timeLimit, markAsBoss)
			end
		end
	end
end

function RaidInstance.onStartup()
	RaidInstance.active = {}
	XmlRaids.register()
	logger.info("[RaidInstance] ready (Lua + XML raids → shared expedition instances)")
end
