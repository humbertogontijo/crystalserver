InstanceWorld = InstanceWorld or {}

InstanceWorld.CITY_BASE = 1000000
InstanceWorld.HUB_ADVENTURERS = 2000000
-- Engine private hunt/raid ids (Game.INSTANCE_PRIVATE_BASE). Dead after restart.
InstanceWorld.PRIVATE_BASE = 3000000
-- Chebyshev radius around hubs[1].center; classify and canWalk must agree.
InstanceWorld.HUB_WALK_RADIUS = 40
InstanceWorld.KV_KEY = "instance_key"

InstanceWorld.cities = InstanceWorld.cities or {}
InstanceWorld.citiesById = InstanceWorld.citiesById or {}
InstanceWorld.settlements = InstanceWorld.settlements or {}
InstanceWorld.settlementsById = InstanceWorld.settlementsById or {}
InstanceWorld.hubs = InstanceWorld.hubs or {}
InstanceWorld.surroundings = InstanceWorld.surroundings or {}
InstanceWorld.teleports = InstanceWorld.teleports or {}
InstanceWorld.teleportsByFrom = InstanceWorld.teleportsByFrom or {}
InstanceWorld.occupancyBySubarea = InstanceWorld.occupancyBySubarea or {}
InstanceWorld.occupancyByCityId = InstanceWorld.occupancyByCityId or {}
InstanceWorld.occupancyBySettlementId = InstanceWorld.occupancyBySettlementId or {}
InstanceWorld.occupancyByHuntId = InstanceWorld.occupancyByHuntId or {}
InstanceWorld.floorSetByInstanceId = InstanceWorld.floorSetByInstanceId or {}
-- Player ids temporarily exempt from auto-leave-on-city-travel (expedition leave→switch).
InstanceWorld._suppressHuntLeave = InstanceWorld._suppressHuntLeave or {}

function InstanceWorld.suppressHuntLeave(player, suppress)
	if not player or not player.getId then
		return
	end
	local pid = player:getId()
	if suppress then
		InstanceWorld._suppressHuntLeave[pid] = true
	else
		InstanceWorld._suppressHuntLeave[pid] = nil
	end
end

function InstanceWorld.rememberFloors(instanceId, floorSet)
	if instanceId and type(floorSet) == "table" then
		InstanceWorld.floorSetByInstanceId[instanceId] = floorSet
		if Game.setInstanceFloors then
			Game.setInstanceFloors(instanceId, floorSet)
		end
	end
end

function InstanceWorld.forgetFloors(instanceId)
	if instanceId then
		InstanceWorld.floorSetByInstanceId[instanceId] = nil
		if Game.setInstanceFloors then
			Game.setInstanceFloors(instanceId, nil)
		end
		if Game.clearInstancePrivateFence and instanceId >= (InstanceWorld.PRIVATE_BASE or 3000000) then
			Game.clearInstancePrivateFence(instanceId)
		end
	end
end

local function zAllowed(instanceId, z)
	local floors = instanceId and InstanceWorld.floorSetByInstanceId[instanceId]
	if not floors then
		return true
	end
	return floors[math.floor(tonumber(z) or -1)] == true
end

function InstanceWorld.cityInstanceId(cityId)
	return InstanceWorld.CITY_BASE + (tonumber(cityId) or 0)
end

--- True for city / settlement / hub (and open-world id 0). False for private hunt/raid instances.
--- Prefer this over expedition-specific checks for headless persistence / logout.
function InstanceWorld.isSafeInstance(playerOrInstanceId)
	local instanceId = playerOrInstanceId
	if type(playerOrInstanceId) == "userdata" or (type(playerOrInstanceId) == "table" and playerOrInstanceId.getInstanceId) then
		if playerOrInstanceId.isInSafeInstance then
			return playerOrInstanceId:isInSafeInstance() == true
		end
		instanceId = playerOrInstanceId.getInstanceId and playerOrInstanceId:getInstanceId() or 0
	end
	instanceId = math.floor(tonumber(instanceId) or 0)
	-- Mirror Game::INSTANCE_PRIVATE_BASE / InstanceWorld.PRIVATE_BASE.
	return instanceId < (InstanceWorld.PRIVATE_BASE or 3000000)
end

function InstanceWorld.posKey(pos)
	if not pos then
		return nil
	end
	return string.format("%d,%d,%d", pos.x, pos.y, pos.z)
end

local function occupancyContains(occ, x, y)
	if not occ or not occ.contains then
		return false
	end
	return occ:contains(x, y) and true or false
end

local function inBoundary(pos, b)
	if not pos or type(b) ~= "table" then
		return false
	end
	local x, y, w, h = tonumber(b.x), tonumber(b.y), tonumber(b.w), tonumber(b.h)
	if not x or not y or not w or not h then
		return false
	end
	return pos.x >= x and pos.x < x + w and pos.y >= y and pos.y < y + h
end

local function inAdventurersHub(pos)
	if not pos then
		return false
	end
	local hub = InstanceWorld.hubs[1] and InstanceWorld.hubs[1].center
	if not hub then
		return false
	end
	local r = InstanceWorld.HUB_WALK_RADIUS
	return math.abs(pos.x - hub.x) <= r and math.abs(pos.y - hub.y) <= r
end

local function loadJson(path)
	local file = io.open(path, "r")
	if not file then
		return nil
	end
	local content = file:read("*a")
	file:close()
	if not ExpeditionJson or not ExpeditionJson.decode then
		return nil
	end
	return ExpeditionJson.decode(content)
end

local function loadMask(overviewFile, boundary)
	if type(overviewFile) ~= "string" or overviewFile == "" or type(boundary) ~= "table" then
		return nil
	end
	if not Game.loadOccupancyMask then
		return nil
	end
	local ox, oy = tonumber(boundary.x), tonumber(boundary.y)
	if not ox or not oy then
		return nil
	end
	local dir = ExpeditionConfig and ExpeditionConfig.SUBAREA_DIR or "tibia/subareas"
	local path = DATA_DIRECTORY .. "/" .. dir .. "/" .. overviewFile
	return Game.loadOccupancyMask(path, ox, oy)
end

local function loadGenerated()
	local catalogPath = DATA_DIRECTORY .. "/lib/idleot/expeditions/catalog.generated.json"
	local catalog = loadJson(catalogPath)
	if type(catalog) == "table" and type(catalog.cities) == "table" then
		InstanceWorld.cities = catalog.cities
		InstanceWorld.citiesById = {}
		for _, city in ipairs(catalog.cities) do
			if city.cityId then
				InstanceWorld.citiesById[city.cityId] = city
			end
			local occ = loadMask(city.overviewFile, city.boundary)
			if occ then
				InstanceWorld.occupancyBySubarea[city.subareaId or city.id] = occ
				InstanceWorld.occupancyByCityId[city.cityId] = occ
				if Game.setInstanceAreaFence and city.cityId then
					Game.setInstanceAreaFence(city.cityId, occ, city.boundary)
				end
			end
			-- Cities are multi-floor (houses, depots, stairs). Occupancy is XY;
			-- do not rememberFloors or zAllowed would lock the catalog surface z.
		end
		logger.info("[InstanceWorld] loaded {} cities", #catalog.cities)
	end

	InstanceWorld.settlements = {}
	InstanceWorld.settlementsById = {}
	if type(catalog) == "table" and type(catalog.settlements) == "table" then
		InstanceWorld.settlements = catalog.settlements
		for _, settlement in ipairs(catalog.settlements) do
			local sid = settlement.id or settlement.subareaId
			if sid then
				InstanceWorld.settlementsById[sid] = settlement
			end
			local occ = loadMask(settlement.overviewFile, settlement.boundary)
			if occ and sid then
				InstanceWorld.occupancyBySubarea[settlement.subareaId or sid] = occ
				InstanceWorld.occupancyBySettlementId[sid] = occ
				if Game.setInstanceAreaFence then
					Game.setInstanceAreaFence(sid, occ, settlement.boundary)
				end
			end
			-- Settlements match cities: XY occupancy, all floors.
		end
		logger.info("[InstanceWorld] loaded {} settlements", #catalog.settlements)
	end

	if type(catalog) == "table" and type(catalog.catalog) == "table" then
		for _, hunt in ipairs(catalog.catalog) do
			local occ = loadMask(hunt.overviewFile, hunt.boundary)
			if occ and hunt.id then
				InstanceWorld.occupancyByHuntId[hunt.id] = occ
			end
		end
	end

	local travelPath = DATA_DIRECTORY .. "/lib/idleot/instance_world/travel.generated.json"
	local travel = loadJson(travelPath)
	if type(travel) ~= "table" then
		logger.warn("[InstanceWorld] missing travel.generated.json")
		return
	end
	InstanceWorld.hubs = travel.hubs or {}
	if ExpeditionInstance and ExpeditionInstance.floorsFromSpec then
		local hub = InstanceWorld.hubs[1]
		local floors, floorSet = ExpeditionInstance.floorsFromSpec(hub, hub and hub.center and hub.center.z)
		InstanceWorld.rememberFloors(InstanceWorld.HUB_ADVENTURERS, floorSet)
		if Game.setInstanceHubFence and hub and hub.center then
			Game.setInstanceHubFence(
				hub.center.x,
				hub.center.y,
				InstanceWorld.HUB_WALK_RADIUS or 40,
				floors
			)
		end
	end
	InstanceWorld.surroundings = travel.surroundings or {}
	InstanceWorld.teleports = travel.teleports or {}
	InstanceWorld.teleportsByFrom = {}
	for _, hop in ipairs(InstanceWorld.teleports) do
		if hop.from then
			InstanceWorld.teleportsByFrom[InstanceWorld.posKey(hop.from)] = hop
		end
	end
	logger.info("[InstanceWorld] travel {} teleports + {} surroundings", #InstanceWorld.teleports, #InstanceWorld.surroundings)
end

loadGenerated()

local function townKey(name)
	return (tostring(name or ""):lower():gsub("%s+", ""))
end

function InstanceWorld.cityForTown(town)
	if not town then
		return InstanceWorld.citiesById[24]
	end
	local name = town.getName and town:getName() or tostring(town)
	if type(name) == "string" then
		local key = townKey(name)
		for _, settlement in ipairs(InstanceWorld.settlements) do
			if settlement.name == name or townKey(settlement.name) == key then
				return settlement
			end
		end
		for _, city in ipairs(InstanceWorld.cities) do
			if city.name == name or city.city == name then
				return city
			end
			if townKey(city.name) == key or townKey(city.city) == key then
				return city
			end
		end
	end
	return InstanceWorld.citiesById[24] or InstanceWorld.cities[1]
end

function InstanceWorld.persist(player, key)
	if not player or not key then
		return
	end
	local kv = player.kv and player:kv()
	if kv then
		kv:set(InstanceWorld.KV_KEY, key)
	end
end

function InstanceWorld.loadKey(player)
	if not player or not player.kv then
		return nil
	end
	local kv = player:kv()
	if not kv or not kv.get then
		return nil
	end
	local key = kv:get(InstanceWorld.KV_KEY)
	if type(key) == "string" and key ~= "" then
		return key
	end
	return nil
end

function InstanceWorld.idForTarget(target)
	if not target then
		return nil
	end
	if target.kind == "city" and target.cityId then
		return InstanceWorld.cityInstanceId(target.cityId)
	end
	if target.kind == "settlement" and target.settlementId then
		return InstanceWorld.cityInstanceId(target.settlementId)
	end
	if target.kind == "hub" then
		return InstanceWorld.HUB_ADVENTURERS
	end
	if target.kind == "hunt" then
		return nil
	end
	return nil
end

function InstanceWorld.classify(dest)
	if not dest then
		return { kind = "blocked" }
	end
	if inAdventurersHub(dest) then
		return { kind = "hub", hubId = "adventurers" }
	end

	for _, settlement in ipairs(InstanceWorld.settlements) do
		local sid = settlement.id or settlement.subareaId
		local occ = sid and InstanceWorld.occupancyBySettlementId[sid] or nil
		if occ then
			if occupancyContains(occ, dest.x, dest.y) then
				return { kind = "settlement", settlementId = sid }
			end
		elseif settlement.boundary and inBoundary(dest, settlement.boundary) then
			return { kind = "settlement", settlementId = sid }
		end
	end

	for _, city in ipairs(InstanceWorld.cities) do
		local occ = InstanceWorld.occupancyByCityId[city.cityId]
		if occ then
			if occupancyContains(occ, dest.x, dest.y) then
				return { kind = "city", cityId = city.cityId }
			end
		elseif city.boundary and inBoundary(dest, city.boundary) then
			return { kind = "city", cityId = city.cityId }
		end
	end

	if ExpeditionConfig and ExpeditionConfig.Catalog then
		for _, hunt in ipairs(ExpeditionConfig.Catalog) do
			local occ = InstanceWorld.occupancyByHuntId[hunt.id]
			if occ then
				if occupancyContains(occ, dest.x, dest.y) then
					return { kind = "hunt", huntId = hunt.id }
				end
			elseif hunt.boundary and inBoundary(dest, hunt.boundary) then
				return { kind = "hunt", huntId = hunt.id }
			end
		end
	end

	for _, row in ipairs(InstanceWorld.surroundings) do
		if inBoundary(dest, row.boundary) then
			return { kind = "blocked" }
		end
	end

	return { kind = "stay" }
end

local function asPlayer(creature)
	if not creature then
		return nil
	end
	if creature.getPlayer then
		return creature:getPlayer()
	end
	if creature.isPlayer and creature:isPlayer() then
		return creature
	end
	return nil
end

--- Client resolves CIP masks locally; only hub still needs a walk AABB.
local function aabbAround(center, radius)
	if not center or not radius then
		return nil
	end
	local r = math.floor(tonumber(radius) or 0)
	return {
		x = center.x - r,
		y = center.y - r,
		w = r * 2 + 1,
		h = r * 2 + 1,
	}
end

InstanceWorld._boundsSent = InstanceWorld._boundsSent or {}
InstanceWorld._boundsPending = InstanceWorld._boundsPending or {}

function InstanceWorld.scheduleSendBounds(player)
	if not player or not player.getId then
		return
	end
	local pid = player:getId()
	if InstanceWorld._boundsPending[pid] then
		return
	end
	InstanceWorld._boundsPending[pid] = true
	addEvent(function(id)
		InstanceWorld._boundsPending[id] = nil
		local p = Player(id)
		if p then
			InstanceWorld.sendBounds(p, true)
		end
	end, 50, pid)
end

local function bindCreature(creature, instanceId)
	if creature and instanceId and creature.setInstanceId then
		creature:setInstanceId(instanceId)
		if creature.getSummons then
			for _, summon in ipairs(creature:getSummons() or {}) do
				if summon and summon.setInstanceId then
					summon:setInstanceId(instanceId)
				end
			end
		end
		local player = asPlayer(creature)
		if player then
			InstanceWorld.scheduleSendBounds(player)
		end
	end
end

local function isGodPlayer(player)
	return PzTeleport and PzTeleport.isGod and PzTeleport.isGod(player)
end

local function liveHuntSession(player)
	if not player or not ExpeditionManager or not ExpeditionManager.getSessionByPlayer then
		return nil
	end
	local session = ExpeditionManager.getSessionByPlayer(player)
	if session and session.state ~= "ended" and session.instance and session.instance.instanceId then
		return session
	end
	return nil
end

--- Member session, or the hunt/raid session for a GOD spectator on a private instance.
local function huntSessionFor(player, engineId)
	local session = liveHuntSession(player)
	if session then
		return session
	end
	if not player or not isGodPlayer(player) then
		return nil
	end
	local id = math.floor(tonumber(engineId) or 0)
	if id < InstanceWorld.PRIVATE_BASE then
		return nil
	end
	if ExpeditionManager and ExpeditionManager.getSessionByInstanceId then
		return ExpeditionManager.getSessionByInstanceId(id)
	end
	return nil
end

function InstanceWorld.syncCreatureInstance(creature)
	if not creature then
		return false
	end
	if creature.getInstanceId and creature:getInstanceId() ~= 0 then
		return false
	end
	local player = asPlayer(creature)
	if not player then
		return false
	end
	local session = liveHuntSession(player)
	if session and session.instance and session.instance.instanceId then
		bindCreature(creature, session.instance.instanceId)
		return true
	end
	return false
end

function InstanceWorld.onEngineTravel(creature, destPos)
	if InstanceWorld._skipEngineTravel then
		return true
	end
	if not creature or not destPos then
		return true
	end

	local player = asPlayer(creature)
	local current = creature.getInstanceId and creature:getInstanceId() or 0
	local session = player and huntSessionFor(player, current) or nil
	-- Hunt holds share world XY with cities/settlements (e.g. Rookgaard graves).
	-- In-session teleports must stay on the private instance - never rebind/leave as
	-- open-world city travel (that clears the hunt HUD and strands the player outside PZ).
	if session and session.instance and session.instance.instanceId then
		if ExpeditionInstance and ExpeditionInstance.contains and ExpeditionInstance.contains(session.instance, destPos) then
			bindCreature(creature, session.instance.instanceId)
			return true
		end
	end

	local target = InstanceWorld.classify(destPos)
	if target.kind == "blocked" then
		return false
	end

	if session and session.instance and session.instance.instanceId and target.kind ~= "city" and target.kind ~= "settlement" and target.kind ~= "hub" then
		bindCreature(creature, session.instance.instanceId)
	end

	if target.kind == "stay" then
		return true
	end

	if current >= 3000000 and target.kind ~= "city" and target.kind ~= "settlement" and target.kind ~= "hub" then
		return true
	end

	local leaveSuppressed = player
		and InstanceWorld._suppressHuntLeave[player:getId()]
	if not leaveSuppressed
		and player
		and ExpeditionManager
		and ExpeditionManager.isInExpedition
		and ExpeditionManager.isInExpedition(player)
	then
		if target.kind == "city" or target.kind == "settlement" or target.kind == "hub" then
			-- From a private hunt, always return to PZ. skipTeleport was stranding players
			-- on wilderness holds after a misclassified force-relocate teleport.
			-- Capture the hunt instance id so a follow-up switch join (new instance)
			-- is not aborted by this delayed leave.
			local fromPrivate = current >= (InstanceWorld.PRIVATE_BASE or 3000000)
			local pid = player:getId()
			local huntInstanceId = current
			addEvent(function()
				local p = Player(pid)
				if not p or not ExpeditionManager.leave then
					return
				end
				if InstanceWorld._suppressHuntLeave[pid] then
					return
				end
				local live = ExpeditionManager.getSessionByPlayer and ExpeditionManager.getSessionByPlayer(p)
				local liveId = live and live.instance and live.instance.instanceId or nil
				if not liveId or liveId ~= huntInstanceId then
					return
				end
				if p.getInstanceId and p:getInstanceId() ~= huntInstanceId then
					return
				end
				ExpeditionManager.leave(p, { silent = true, skipTeleport = not fromPrivate })
			end, 50)
		end
	end

	if target.kind == "city" then
		bindCreature(creature, InstanceWorld.cityInstanceId(target.cityId))
		if player then
			InstanceWorld.persist(player, "city:" .. tostring(target.cityId))
		end
		return true
	end
	if target.kind == "settlement" then
		bindCreature(creature, InstanceWorld.cityInstanceId(target.settlementId))
		if player then
			InstanceWorld.persist(player, "settlement:" .. tostring(target.settlementId))
		end
		return true
	end
	if target.kind == "hub" then
		bindCreature(creature, InstanceWorld.HUB_ADVENTURERS)
		if player then
			InstanceWorld.persist(player, "hub:adventurers")
		end
		return true
	end
	if target.kind == "hunt" then
		if session and session.instance and session.instance.instanceId then
			bindCreature(creature, session.instance.instanceId)
			return true
		end
		-- Unscheduled hunt dest: stay on current instance (HUD starts the private copy).
		return true
	end
	return true
end

function InstanceWorld.travel(creature, destPos)
	if not creature or not destPos then
		return false
	end
	if not InstanceWorld.onEngineTravel(creature, destPos) then
		return false
	end
	return creature:teleportTo(destPos) and true or false
end

function InstanceWorld.enterInstance(creature, instanceId, destPos, persistKey)
	if not creature or not instanceId then
		return false
	end
	bindCreature(creature, instanceId)
	local player = creature.getPlayer and creature:getPlayer() or creature
	if persistKey and player and player.kv then
		InstanceWorld.persist(player, persistKey)
	end
	if destPos then
		InstanceWorld._skipEngineTravel = true
		local ok = creature:teleportTo(destPos) and true or false
		InstanceWorld._skipEngineTravel = false
		return ok
	end
	return true
end

function InstanceWorld.canWalk(creature, destPos)
	if Game.canWalkInstance then
		return Game.canWalkInstance(creature, destPos) and true or false
	end
	if not creature or not destPos then
		return true
	end
	local instanceId = creature.getInstanceId and creature:getInstanceId() or 0
	if instanceId == 0 then
		return false
	end
	-- City / settlement instances allow every z (stairs, houses, depots).
	-- Hunts, hub, and home still use the declared floor set.
	local cityRange = instanceId >= InstanceWorld.CITY_BASE and instanceId < InstanceWorld.HUB_ADVENTURERS
	if not cityRange and not zAllowed(instanceId, destPos.z) then
		return false
	end
	if instanceId == InstanceWorld.HUB_ADVENTURERS then
		if not (InstanceWorld.hubs[1] and InstanceWorld.hubs[1].center) then
			return true
		end
		return inAdventurersHub(destPos)
	end
	if instanceId >= InstanceWorld.CITY_BASE and instanceId < InstanceWorld.HUB_ADVENTURERS then
		local areaId = instanceId - InstanceWorld.CITY_BASE
		local settlementOcc = InstanceWorld.occupancyBySettlementId[areaId]
		if settlementOcc then
			return occupancyContains(settlementOcc, destPos.x, destPos.y)
		end
		local settlement = InstanceWorld.settlementsById[areaId]
		if settlement and settlement.boundary then
			return inBoundary(destPos, settlement.boundary)
		end
		local occ = InstanceWorld.occupancyByCityId[areaId]
		if occ then
			return occupancyContains(occ, destPos.x, destPos.y)
		end
		local city = InstanceWorld.citiesById[areaId]
		if city and city.boundary then
			return inBoundary(destPos, city.boundary)
		end
		return true
	end
	-- Private hunt / raid: occupancy of the bound session when present.
	local player = creature.getPlayer and creature:getPlayer() or nil
	local session = player and huntSessionFor(player, instanceId) or nil
	if session and session.instance and session.instance.instanceId == instanceId then
		return ExpeditionInstance.contains(session.instance, destPos)
	end
	if player and PlayerHomeManager and PlayerHomeManager.getSession then
		local homeSession = PlayerHomeManager.getSession(player)
		local homeInst = homeSession and homeSession.instance
		if homeInst and homeInst.instanceId == instanceId then
			return PlayerHomeInstance.contains(homeInst, destPos)
		end
	end
	if creature.isMonster and creature:isMonster() then
		return true
	end
	local isPlayer = player
	if not isPlayer and creature.isPlayer and creature:isPlayer() then
		isPlayer = creature
	end
	if isPlayer then
		-- Engine private hunt / raid / home ids must not fall through to open-world walk.
		if instanceId >= InstanceWorld.PRIVATE_BASE then
			if isGodPlayer(isPlayer) and not session then
				return true
			end
			return false
		end
	end
	return true
end

--- Block creature drags/pushes that would leave instance occupancy.
function InstanceWorld.canMoveCreature(pusher, creature, _fromPos, toPos)
	if not creature or not toPos then
		return true
	end
	if not InstanceWorld.canWalk(creature, toPos) then
		return false
	end
	if pusher and pusher ~= creature and pusher.getPosition then
		local pusherPos = pusher:getPosition()
		if pusherPos and not InstanceWorld.canWalk(pusher, pusherPos) then
			return false
		end
	end
	return true
end

function InstanceWorld.describeCurrent(player)
	if not player or not player.getInstanceId then
		return nil
	end
	local engineId = player:getInstanceId() or 0
	if engineId == 0 then
		return nil
	end
	-- Identity protocol: instanceId = subarea (place) id, channel = shard on that place.
	-- Engine binding stays on player:getInstanceId() / session.instance.instanceId.
	if engineId == InstanceWorld.HUB_ADVENTURERS then
		local hub = InstanceWorld.hubs[1]
		local center = hub and hub.center or nil
		return {
			instanceId = 0,
			kind = "hub",
			name = (hub and hub.name) or "Adventurers' Guild",
			key = "hub:adventurers",
			channel = 0,
			bounds = aabbAround(center, InstanceWorld.HUB_WALK_RADIUS),
		}
	end
	if engineId >= InstanceWorld.CITY_BASE and engineId < InstanceWorld.HUB_ADVENTURERS then
		local areaId = engineId - InstanceWorld.CITY_BASE
		local settlement = InstanceWorld.settlementsById[areaId]
		if settlement then
			local subareaId = tonumber(settlement.subareaId or settlement.id) or areaId
			return {
				instanceId = subareaId,
				kind = "settlement",
				name = settlement.name or ("Settlement " .. tostring(subareaId)),
				key = "settlement:" .. tostring(subareaId),
				channel = 0,
			}
		end
		local city = InstanceWorld.citiesById[areaId]
		local subareaId = tonumber(city and (city.subareaId or city.id)) or areaId
		return {
			instanceId = subareaId,
			kind = "city",
			name = (city and (city.name or city.city)) or ("City " .. tostring(subareaId)),
			key = "city:" .. tostring(subareaId),
			channel = 0,
		}
	end
	local session = huntSessionFor(player, engineId)
	if session and session.instance then
		local inst = session.instance
		local kind = session.kind == "raid" and "raid" or "hunt"
		local name = (session.catalog and session.catalog.name)
			or session.displayName
			or session.raidName
			or "Hunt"
		local subareaId = tonumber(session.catalog and session.catalog.id)
			or tonumber(inst.region)
			or 0
		-- Raids are public (channel 0). Private hunts use the team's allocated channel.
		local channel = kind == "raid" and 0 or math.floor(tonumber(session.channel) or 0)
		return {
			instanceId = subareaId,
			kind = kind,
			name = name,
			key = kind .. ":" .. tostring(session.catalog and session.catalog.id or inst.region or subareaId),
			channel = channel,
		}
	end
	if PlayerHomeManager and PlayerHomeManager.getSession then
		local homeSession = PlayerHomeManager.getSession(player)
		local homeInst = homeSession and homeSession.instance
		if homeInst and homeInst.instanceId and engineId == homeInst.instanceId then
			local origin = homeInst.origin
			local w = homeInst.width or (PlayerHomeConfig and PlayerHomeConfig.OUTER_SIZE) or 9
			local h = homeInst.height or (PlayerHomeConfig and PlayerHomeConfig.OUTER_SIZE) or 9
			local bounds = nil
			if origin then
				bounds = { x = origin.x, y = origin.y, w = w, h = h }
			end
			return {
				instanceId = (PlayerHomeConfig and PlayerHomeConfig.PLACE_ID) or 0,
				kind = "home",
				name = "Home",
				key = "home",
				channel = math.floor(tonumber(homeSession.channel or homeInst.channel) or 0),
				bounds = bounds,
			}
		end
	end
	return {
		instanceId = 0,
		kind = "unknown",
		name = "Instance",
		key = "instance:" .. tostring(engineId),
		channel = 0,
	}
end

function InstanceWorld.sendBounds(player, force)
	if not player then
		return false
	end
	if not ExpeditionProtocol or not ExpeditionProtocol.sendInstanceBounds then
		return false
	end
	local desc = InstanceWorld.describeCurrent(player)
	local placeId = desc and desc.instanceId or 0
	local channel = desc and desc.channel or 0
	local pid = player.getId and player:getId() or 0
	local cacheKey = tostring(placeId) .. ":" .. tostring(channel)
	if not force and InstanceWorld._boundsSent[pid] == cacheKey then
		return true
	end
	InstanceWorld._boundsSent[pid] = cacheKey
	return ExpeditionProtocol.sendInstanceBounds(player, desc)
end

local function isHomePosition(pos)
	if not pos then
		return false
	end
	local cfg = PlayerHomeConfig
	if not cfg or not cfg.INSTANCE_BASE_X then
		return pos.x >= 62000
	end
	return pos.x >= cfg.INSTANCE_BASE_X and pos.y >= (cfg.INSTANCE_BASE_Y or 0)
end

local function validRescueDest(pos)
	if not pos then
		return false
	end
	local target = InstanceWorld.classify(pos)
	if target.kind ~= "city" and target.kind ~= "settlement" and target.kind ~= "hub" then
		return false
	end
	-- Shared city/hunt XY must not be treated as a safe return.
	if target.kind ~= "hub" and InstanceWorld.occupancyByHuntId then
		for _, occ in pairs(InstanceWorld.occupancyByHuntId) do
			if occ and occ.contains and occ:contains(pos.x, pos.y) then
				return false
			end
		end
	end
	return true
end

local function asWorldPos(pos)
	if not pos then
		return nil
	end
	if tonumber(pos.x) and tonumber(pos.y) then
		return pos
	end
	return nil
end

function InstanceWorld.rescuePos(player)
	local dest = nil
	if ExpeditionManager and ExpeditionManager.loadReturnPos then
		dest = ExpeditionManager.loadReturnPos(player)
	end
	if not validRescueDest(dest) then
		local town = player.getTown and player:getTown() or nil
		if town and town.getTemplePosition then
			dest = town:getTemplePosition()
		end
	end
	if not validRescueDest(dest) then
		local city = InstanceWorld.cityForTown(player.getTown and player:getTown() or nil)
		if city and city.center then
			dest = Position(city.center.x, city.center.y, city.center.z)
		end
	end
	return dest or Position(32369, 32241, 7)
end

local function bindSafeCity(player)
	local dest = InstanceWorld.rescuePos(player)
	local target = InstanceWorld.classify(dest)
	if target.kind == "hub" then
		bindCreature(player, InstanceWorld.HUB_ADVENTURERS)
		InstanceWorld.persist(player, "hub:adventurers")
		return dest
	end
	if target.kind == "settlement" and target.settlementId then
		bindCreature(player, InstanceWorld.cityInstanceId(target.settlementId))
		InstanceWorld.persist(player, "settlement:" .. tostring(target.settlementId))
		return dest
	end
	local cityId = target.kind == "city" and target.cityId or nil
	if not cityId then
		local area = InstanceWorld.cityForTown(player.getTown and player:getTown() or nil)
		if area and area.kind == "settlement" then
			bindCreature(player, InstanceWorld.cityInstanceId(area.id or area.subareaId))
			InstanceWorld.persist(player, "settlement:" .. tostring(area.id or area.subareaId))
			return dest
		end
		cityId = area and area.cityId or 24
	end
	bindCreature(player, InstanceWorld.cityInstanceId(cityId))
	InstanceWorld.persist(player, "city:" .. tostring(cityId))
	return dest
end

local function sameTile(a, b)
	return a and b and a.x == b.x and a.y == b.y and a.z == b.z
end

--- Leave a private hunt/raid instance for city/settlement/hub.
--- Unlike travel(), this always rebinds off PRIVATE_BASE and never relies on
--- classify(returnPos) succeeding while still on a hunt footprint.
--- Handles same-tile returns (engine teleportTo refuses identical XY/Z).
function InstanceWorld.exitToOpenWorld(player, destPos)
	if not player then
		return false
	end
	local wasPrivate = (player.getInstanceId and player:getInstanceId() or 0) >= InstanceWorld.PRIVATE_BASE
	destPos = asWorldPos(destPos) or InstanceWorld.rescuePos(player)
	local target = InstanceWorld.classify(destPos)
	if target.kind == "hub" then
		bindCreature(player, InstanceWorld.HUB_ADVENTURERS)
		InstanceWorld.persist(player, "hub:adventurers")
	elseif target.kind == "settlement" and target.settlementId then
		bindCreature(player, InstanceWorld.cityInstanceId(target.settlementId))
		InstanceWorld.persist(player, "settlement:" .. tostring(target.settlementId))
	elseif target.kind == "city" and target.cityId then
		bindCreature(player, InstanceWorld.cityInstanceId(target.cityId))
		InstanceWorld.persist(player, "city:" .. tostring(target.cityId))
	else
		-- Hunt / blocked / stay return would leave the player on PRIVATE_BASE.
		destPos = bindSafeCity(player)
	end

	local cur = player.getPosition and player:getPosition() or nil
	-- Leaving a private hold must change tiles when return XY matches the hunt
	-- footprint (shared city/hunt occupancy). Same-tile setInstanceId alone looks
	-- like "stuck on the expedition".
	if wasPrivate and sameTile(cur, destPos) then
		local town = player.getTown and player:getTown() or nil
		if town and town.getTemplePosition then
			destPos = town:getTemplePosition()
		else
			destPos = Position(32369, 32241, 7)
		end
		local safe = InstanceWorld.classify(destPos)
		if safe.kind == "hub" then
			bindCreature(player, InstanceWorld.HUB_ADVENTURERS)
			InstanceWorld.persist(player, "hub:adventurers")
		elseif safe.kind == "settlement" and safe.settlementId then
			bindCreature(player, InstanceWorld.cityInstanceId(safe.settlementId))
			InstanceWorld.persist(player, "settlement:" .. tostring(safe.settlementId))
		elseif safe.kind == "city" and safe.cityId then
			bindCreature(player, InstanceWorld.cityInstanceId(safe.cityId))
			InstanceWorld.persist(player, "city:" .. tostring(safe.cityId))
		else
			bindCreature(player, InstanceWorld.cityInstanceId(24))
			InstanceWorld.persist(player, "city:24")
		end
		cur = player.getPosition and player:getPosition() or nil
	elseif sameTile(cur, destPos) then
		InstanceWorld.scheduleSendBounds(player)
		return true
	end

	if not (player.getTile and player:getTile()) then
		return false
	end
	InstanceWorld._skipEngineTravel = true
	local ok = player:teleportTo(destPos) and true or false
	InstanceWorld._skipEngineTravel = false
	if not ok then
		destPos = bindSafeCity(player)
		cur = player.getPosition and player:getPosition() or nil
		if not sameTile(cur, destPos) and player.getTile and player:getTile() then
			InstanceWorld._skipEngineTravel = true
			ok = player:teleportTo(destPos) and true or false
			InstanceWorld._skipEngineTravel = false
		else
			ok = (player.getInstanceId and player:getInstanceId() or 0) < InstanceWorld.PRIVATE_BASE
		end
	end
	if ok then
		InstanceWorld.scheduleSendBounds(player)
	end
	return ok
end

--- Hunt/raid tiles or a leftover hunt instance after the in-memory session is gone.
function InstanceWorld.isStrandedExpedition(player, pos)
	if not player then
		return false
	end
	if liveHuntSession(player) then
		return false
	end
	pos = asWorldPos(pos)
	if isHomePosition(pos) then
		return false
	end
	local instanceId = player.getInstanceId and player:getInstanceId() or 0
	if instanceId >= InstanceWorld.PRIVATE_BASE then
		return true
	end
	local key = InstanceWorld.loadKey(player)
	if type(key) == "string" and (key:match("^hunt:") or key:match("^raid:")) then
		return true
	end
	if ExpeditionConfig and player.getStorageValue and player:getStorageValue(ExpeditionConfig.STORAGE_ACTIVE) == 1 then
		return true
	end
	if pos then
		local target = InstanceWorld.classify(pos)
		if target.kind == "hunt" or target.kind == "blocked" then
			return true
		end
		-- Misclassified leave: still on a hunt footprint (city/settlement wins classify)
		-- with Play-expedition UI and no PZ - rescue to temple on login.
		local tile = player.getTile and player:getTile() or nil
		local inPz = tile and tile.hasFlag and tile:hasFlag(TILESTATE_PROTECTIONZONE)
		if not inPz and ExpeditionConfig and ExpeditionConfig.Catalog then
			for _, hunt in ipairs(ExpeditionConfig.Catalog) do
				local occ = hunt.id and InstanceWorld.occupancyByHuntId[hunt.id] or nil
				if occ and occupancyContains(occ, pos.x, pos.y) then
					return true
				end
				if not occ and hunt.boundary and inBoundary(pos, hunt.boundary) then
					return true
				end
			end
		end
	end
	return false
end

function InstanceWorld.shouldRescue(player)
	if not player then
		return false
	end
	if ExpeditionManager and ExpeditionManager.hasPendingRestore and ExpeditionManager.hasPendingRestore(player) then
		return false
	end
	-- Waiting / starting sessions keep members in the city until synchronized entry.
	-- Do not treat private-instance binding (or hunt tiles) as stranded yet.
	local session = liveHuntSession(player)
	if session and (not session.entered or session.starting) then
		return false
	end
	local pos = player.getPosition and player:getPosition() or nil
	if InstanceWorld.isStrandedExpedition(player, pos) then
		return true
	end
	if isHomePosition(pos) then
		return false
	end
	if pos and not InstanceWorld.canWalk(player, pos) then
		local engineId = player.getInstanceId and player:getInstanceId() or 0
		if isGodPlayer(player) and engineId >= InstanceWorld.PRIVATE_BASE then
			return false
		end
		return true
	end
	return false
end

function InstanceWorld.rescueIfStranded(player)
	if not InstanceWorld.shouldRescue(player) then
		return false
	end
	local dest = bindSafeCity(player)
	if ExpeditionManager and ExpeditionManager.clearActiveFlag then
		ExpeditionManager.clearActiveFlag(player)
	end
	if ExpeditionManager and ExpeditionManager.clearAreaEffects then
		ExpeditionManager.clearAreaEffects(player)
	end
	if player.setIdleCombat then
		player:setIdleCombat(false)
	end
	if not (player.getTile and player:getTile()) then
		return false
	end
	InstanceWorld._skipEngineTravel = true
	local ok = player:teleportTo(dest) and true or false
	InstanceWorld._skipEngineTravel = false
	if ok then
		local now = player:getPosition()
		if now then
			now:sendMagicEffect(CONST_ME_TELEPORT)
		end
		player:sendTextMessage(MESSAGE_EVENT_ADVANCE, "Your expedition was interrupted. You were returned to safety.")
	end
	return ok
end

function InstanceWorld.bindLogin(player, loginPos)
	if not player or not player.setInstanceId then
		return
	end
	local session = liveHuntSession(player)
	if session then
		bindCreature(player, session.instance.instanceId)
		return
	end
	local pos = asWorldPos(loginPos) or (player.getPosition and player:getPosition() or nil)
	if InstanceWorld.isStrandedExpedition(player, pos) then
		bindSafeCity(player)
		if player.getTile and player:getTile() then
			InstanceWorld.rescueIfStranded(player)
		end
		return
	end
	local target = InstanceWorld.classify(pos)
	if target.kind == "city" and target.cityId then
		bindCreature(player, InstanceWorld.cityInstanceId(target.cityId))
		InstanceWorld.persist(player, "city:" .. tostring(target.cityId))
		return
	end
	if target.kind == "settlement" and target.settlementId then
		bindCreature(player, InstanceWorld.cityInstanceId(target.settlementId))
		InstanceWorld.persist(player, "settlement:" .. tostring(target.settlementId))
		return
	end
	if target.kind == "hub" then
		bindCreature(player, InstanceWorld.HUB_ADVENTURERS)
		InstanceWorld.persist(player, "hub:adventurers")
		return
	end
	local key = InstanceWorld.loadKey(player)
	if type(key) == "string" then
		local cityId = key:match("^city:(%d+)$")
		if cityId then
			bindCreature(player, InstanceWorld.cityInstanceId(tonumber(cityId)))
			return
		end
		local settlementId = key:match("^settlement:(%d+)$")
		if settlementId then
			bindCreature(player, InstanceWorld.cityInstanceId(tonumber(settlementId)))
			return
		end
		if key == "hub:adventurers" then
			bindCreature(player, InstanceWorld.HUB_ADVENTURERS)
			return
		end
	end
	local area = InstanceWorld.cityForTown(player.getTown and player:getTown() or nil)
	if area and area.kind == "settlement" then
		local sid = area.id or area.subareaId
		bindCreature(player, InstanceWorld.cityInstanceId(sid))
		InstanceWorld.persist(player, "settlement:" .. tostring(sid))
		return
	end
	local cityId = area and area.cityId or 24
	bindCreature(player, InstanceWorld.cityInstanceId(cityId))
	InstanceWorld.persist(player, "city:" .. tostring(cityId))
end

function InstanceWorld.tagCityNpcs()
	if not Game.getNpcs then
		return
	end
	local tagged = 0
	for _, npc in ipairs(Game.getNpcs()) do
		if npc and npc.getPosition then
			local pos = npc:getPosition()
			local target = InstanceWorld.classify(pos)
			if target.kind == "city" and target.cityId then
				npc:setInstanceId(InstanceWorld.cityInstanceId(target.cityId))
				tagged = tagged + 1
			elseif target.kind == "settlement" and target.settlementId then
				npc:setInstanceId(InstanceWorld.cityInstanceId(target.settlementId))
				tagged = tagged + 1
			elseif target.kind == "hub" then
				npc:setInstanceId(InstanceWorld.HUB_ADVENTURERS)
				tagged = tagged + 1
			end
		end
	end
	logger.info("[InstanceWorld] tagged {} city/settlement/hub NPCs", tagged)
end

local FORGE_FIENDISH = 2
local FORGE_INFLUENCED = 1

local function countWorldSpawnSlots()
	local mapName = "world"
	if configManager and configKeys and configKeys.MAP_NAME then
		mapName = configManager.getString(configKeys.MAP_NAME) or mapName
	end
	local path = DATA_DIRECTORY .. "/world/" .. mapName .. "-monster.xml"
	local file = io.open(path, "r")
	if not file then
		return 0
	end
	local n = 0
	for line in file:lines() do
		if line:find("spawntime=", 1, true) then
			n = n + 1
		end
	end
	file:close()
	return n
end

local function forgeLimit(key, fallback)
	if configManager and configKeys and key then
		local n = tonumber(configManager.getNumber(key))
		if n and n > 0 then
			return n
		end
	end
	return fallback
end

--- Match open-world forge density: `forgeFiendishLimit` / world spawn slots (not the
--- server-wide cap dumped onto the handful of hunt creatures).
function InstanceWorld.applyOpenWorldForge(monster)
	if not monster or not monster.isForgeable or not monster:isForgeable() then
		return monster
	end
	local population = tonumber(InstanceWorld.worldSpawnSlots) or 0
	if population < 1 then
		return monster
	end
	local fiendishLimit = forgeLimit(configKeys and configKeys.FORGE_FIENDISH_CREATURES_LIMIT, 4)
	local influencedLimit = forgeLimit(configKeys and configKeys.FORGE_INFLUENCED_CREATURES_LIMIT, 300)
	local roll = math.random()
	local fiendishChance = fiendishLimit / population
	if roll < fiendishChance then
		monster:setMonsterForgeClassification(FORGE_FIENDISH)
		if monster.configureForgeSystem then
			monster:configureForgeSystem()
		end
	elseif roll < fiendishChance + (influencedLimit / population) then
		monster:setMonsterForgeClassification(FORGE_INFLUENCED)
		if monster.configureForgeSystem then
			monster:configureForgeSystem()
		end
	end
	return monster
end

function InstanceWorld.onStartup()
	InstanceWorld.worldSpawnSlots = countWorldSpawnSlots()
	if InstanceWorld.worldSpawnSlots > 0 then
		logger.info(
			"[InstanceWorld] open-world forge rate uses {} spawn slots (fiendish {}, influenced {})",
			InstanceWorld.worldSpawnSlots,
			forgeLimit(configKeys and configKeys.FORGE_FIENDISH_CREATURES_LIMIT, 4),
			forgeLimit(configKeys and configKeys.FORGE_INFLUENCED_CREATURES_LIMIT, 300)
		)
	else
		logger.warn("[InstanceWorld] world-monster.xml spawn count is 0; hunt forge rolls disabled")
	end
	if Game.disableWorldSpawns then
		Game.disableWorldSpawns()
		logger.info("[InstanceWorld] world spawn.xml activity disabled")
	end
	InstanceWorld.tagCityNpcs()
end
