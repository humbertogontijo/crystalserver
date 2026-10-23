InstanceWorld = InstanceWorld or {}

InstanceWorld.HUB_ADVENTURERS = Instance.HUB
-- Chebyshev radius around hubs[1].center; classify and canWalk must agree.
InstanceWorld.HUB_WALK_RADIUS = 40

InstanceWorld.cities = InstanceWorld.cities or {}
InstanceWorld.citiesById = InstanceWorld.citiesById or {}
InstanceWorld.citiesBySubareaId = InstanceWorld.citiesBySubareaId or {}
InstanceWorld.hubs = InstanceWorld.hubs or {}
InstanceWorld.surroundings = InstanceWorld.surroundings or {}
InstanceWorld.teleports = InstanceWorld.teleports or {}
InstanceWorld.teleportsByFrom = InstanceWorld.teleportsByFrom or {}
InstanceWorld.occupancyBySubarea = InstanceWorld.occupancyBySubarea or {}
InstanceWorld.occupancyByCityId = InstanceWorld.occupancyByCityId or {}
InstanceWorld.occupancyByHuntId = InstanceWorld.occupancyByHuntId or {}
InstanceWorld.houses = InstanceWorld.houses or {}
InstanceWorld.housesById = InstanceWorld.housesById or {}
InstanceWorld.occupancyByHouseId = InstanceWorld.occupancyByHouseId or {}
-- Player ids temporarily exempt from auto-leave-on-city-travel (expedition leave→switch).
InstanceWorld._suppressHuntLeave = InstanceWorld._suppressHuntLeave or {}

function InstanceWorld.suppressHuntLeave(player, suppress)
	if not player then
		return
	end
	local pid = player:getId()
	if suppress then
		InstanceWorld._suppressHuntLeave[pid] = true
	else
		InstanceWorld._suppressHuntLeave[pid] = nil
	end
end

--- Engine floor gate of `instanceId` (released with the channel).
function InstanceWorld.rememberFloors(instanceId, floorSet)
	if instanceId and type(floorSet) == "table" then
		Game.setInstanceFloors(instanceId, floorSet)
	end
end

--- City / house: catalog area kinds (C++ isAreaKind). CIP AreaData is city SoT.
local function isAreaKind(kind)
	return kind == "city" or kind == "house"
end

--- Instance kind + subarea id of a catalog city row.
function InstanceWorld.areaIdentity(area)
	if type(area) ~= "table" then
		return nil, nil
	end
	local kind = "city"
	local subareaId = tonumber(area.subareaId or area.id)
	if not subareaId then
		return nil, nil
	end
	return kind, subareaId
end

--- Public channel of {kind, subareaId} for `player`: their current one when already there,
--- else their party's, else the lowest non-full one (engine pickChannel). nil when the
--- engine cannot open one; callers must not invent a key.
function InstanceWorld.pickInstance(player, kind, subareaId)
	local picked = Game.pickInstanceChannel(kind, subareaId, nil, player)
	if not picked then
		logger.error("[InstanceWorld] no channel available for {}:{}", tostring(kind), tostring(subareaId))
	end
	return picked
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
	return JsonParser.decode(content)
end

local function loadMask(overviewFile, boundary)
	if type(overviewFile) ~= "string" or overviewFile == "" or type(boundary) ~= "table" then
		return nil
	end
	local ox, oy = tonumber(boundary.x), tonumber(boundary.y)
	if not ox or not oy then
		return nil
	end
	local dir = ExpeditionConfig and ExpeditionConfig.SUBAREA_DIR or "lib/idleot/subareas"
	local path = DATA_DIRECTORY .. "/" .. dir .. "/" .. overviewFile
	return Game.loadOccupancyMask(path, ox, oy)
end

local function loadGenerated()
	local catalogPath = DATA_DIRECTORY .. "/lib/idleot/expeditions/catalog.generated.json"
	local catalog = loadJson(catalogPath)
	if type(catalog) == "table" and type(catalog.cities) == "table" then
		InstanceWorld.cities = catalog.cities
		InstanceWorld.citiesById = {}
		InstanceWorld.citiesBySubareaId = {}
		for _, city in ipairs(catalog.cities) do
			if city.cityId then
				InstanceWorld.citiesById[city.cityId] = city
			end
			local kind, subareaId = InstanceWorld.areaIdentity(city)
			if subareaId then
				InstanceWorld.citiesBySubareaId[subareaId] = city
			end
			local occ = loadMask(city.overviewFile, city.boundary)
			if occ then
				InstanceWorld.occupancyBySubarea[city.subareaId or city.id] = occ
				InstanceWorld.occupancyByCityId[city.cityId] = occ
				if subareaId then
					Game.setInstanceAreaFence(kind, subareaId, occ, city.boundary)
				end
			end
			-- Cities are multi-floor (houses, depots, stairs). Occupancy is XY;
			-- do not rememberFloors or the engine would lock the catalog surface z.
		end
		logger.info("[InstanceWorld] loaded {} cities", #catalog.cities)
	end

	-- Houses (CIP staticdata + OTBM footprints) — separate public instance kind.
	InstanceWorld.houses = {}
	InstanceWorld.housesById = {}
	InstanceWorld.occupancyByHouseId = {}
	local housesPath = DATA_DIRECTORY .. "/lib/idleot/instance_world/houses.generated.json"
	local housesFile = loadJson(housesPath)
	local houseList = type(housesFile) == "table" and (housesFile.houses or housesFile) or nil
	if type(houseList) == "table" then
		InstanceWorld.houses = houseList
		local loaded = 0
		for _, house in ipairs(houseList) do
			local hid = house.id
			if hid then
				InstanceWorld.housesById[hid] = house
			end
			local occ = loadMask(house.overviewFile, house.boundary)
			if occ and hid then
				InstanceWorld.occupancyByHouseId[hid] = occ
				Game.setInstanceAreaFence("house", hid, occ, house.boundary)
				loaded = loaded + 1
			end
		end
		logger.info("[InstanceWorld] loaded {} houses ({} fences)", #houseList, loaded)
	end

	if type(catalog) == "table" and type(catalog.catalog) == "table" then
		local huntMasks = 0
		local huntMissing = 0
		for _, hunt in ipairs(catalog.catalog) do
			local occ = loadMask(hunt.overviewFile, hunt.boundary)
			if occ and hunt.id then
				InstanceWorld.occupancyByHuntId[hunt.id] = occ
				InstanceWorld.occupancyBySubarea[hunt.id] = occ
				huntMasks = huntMasks + 1
			elseif hunt.overviewFile and hunt.overviewFile ~= "" then
				huntMissing = huntMissing + 1
			end
		end
		logger.info(
			"[InstanceWorld] loaded {} hunt occupancy masks ({} missing files)",
			huntMasks,
			huntMissing
		)
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
		if hub and hub.center then
			Game.setInstanceHubFence(
				hub.center.x,
				hub.center.y,
				InstanceWorld.HUB_WALK_RADIUS or 40,
				floors,
				hub.center.z
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
	local name = town:getName() or tostring(town)
	if type(name) == "string" then
		local key = townKey(name)
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

--- Engine instance record ({key, kind, owner, private}) as of the last logout; the engine
--- rewrites `instance` on every instance change, so login code reads this snapshot.
function InstanceWorld.loginRecord(player)
	if not player then
		return nil
	end
	local record = player:kv():get("instance_login")
	if type(record) == "table" and type(record.key) == "string" then
		return record
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

	-- Multi-floor subarea regions: city regions keep their kind (connectors
	-- resolve to their main owner); every other region is "open" (open-world hunt/wild).
	if Game.isSubareaInstancesEnabled() then
		local region = Game.getSubareaAt(Position(dest.x, dest.y, dest.z))
		if region and region.instance then
			local instanceKind = Instance.kind(region.instance)
			local subareaId = Instance.subareaId(region.instance)
			local kind = isAreaKind(instanceKind) and instanceKind or "open"
			return { kind = kind, instanceKind = instanceKind, subareaId = subareaId, region = region }
		end
	end


	for _, city in ipairs(InstanceWorld.cities) do
		local occ = InstanceWorld.occupancyByCityId[city.cityId]
		if occ then
			if occupancyContains(occ, dest.x, dest.y) then
				return { kind = "city", subareaId = tonumber(city.subareaId or city.id) }
			end
		elseif city.boundary and inBoundary(dest, city.boundary) then
			return { kind = "city", subareaId = tonumber(city.subareaId or city.id) }
		end
	end

	local hunt = InstanceWorld.huntAt(dest)
	if hunt then
		return { kind = "hunt", huntId = hunt.id }
	end

	for _, row in ipairs(InstanceWorld.surroundings) do
		if inBoundary(dest, row.boundary) then
			return { kind = "blocked" }
		end
	end

	return { kind = "stay" }
end

--- Subarea (region) id at `pos`; 0 when unknown.
function InstanceWorld.subareaIdAt(pos)
	if not pos then
		return 0
	end
	local region = Game.getSubareaAt(Position(pos.x, pos.y, pos.z))
	if region and region.id then
		return region.id
	end
	-- Only subarea ids: catalog hunt ids live in another namespace.
	return InstanceWorld.classify(pos).subareaId or 0
end

local function asPlayer(creature)
	return creature and creature:getPlayer()
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

--- playerOnChangeInstance: push the new identity. Deferred one tick: the instance changes
--- before the teleport moves the player, and the expedition hint (openWorldHunt) looks hunts
--- up by position. A login bind runs before the player is on the map; playerOnClientReady
--- sends that one.
function InstanceWorld.onChangeInstance(player)
	if player:getTile() then
		local pid = player:getId()
		addEvent(function()
			local p = Player(pid)
			if p and p:getTile() then
				InstanceWorld.sendBounds(p, true)
			end
		end, 0)
	end
	IdleEvents.emit("player.instanceChanged", player)
end

--- Only players change instance; C++ moves their summons along. Monsters/NPCs are
--- born in their instance and never rebound.
local function bindCreature(creature, instanceId)
	if not creature or not instanceId then
		return
	end
	local player = asPlayer(creature)
	if not player then
		return
	end
	player:setInstanceId(instanceId)
end

--- Region display name ("Thais Surroundings"); nil when unknown.
function InstanceWorld.subareaName(subareaId)
	local info = Game.getSubareaInfo(tonumber(subareaId) or 0)
	return info and info.name or nil
end

--- GM /instance: rebind a player to `instanceId` without moving them.
function InstanceWorld.setInstanceInPlace(player, instanceId)
	local p = asPlayer(player)
	return p ~= nil and p:setInstanceId(instanceId) == true
end

--- classify kinds that bind a public layer on arrival ("open" = non-city subarea region).
local function isPublicBindKind(kind)
	return isAreaKind(kind) or kind == "hub" or kind == "open"
end

--- Resolve destination instance for open-world classify targets (no bind).
local function instanceIdForTarget(target, player)
	if not target then
		return nil
	end
	local key = nil
	if target.kind == "hub" then
		key = InstanceWorld.pickInstance(player, "hub", Instance.subareaId(InstanceWorld.HUB_ADVENTURERS))
	elseif target.region then
		-- Stay on the current public layer while it owns the region (connectors are sticky).
		local current = player and Instance.of(player) or nil
		if current and Instance.isOpenWorld(current) then
			local currentId = Instance.subareaId(current)
			local owned = currentId == target.region.id
			if not owned then
				for _, owner in ipairs(target.region.owners or {}) do
					if owner == currentId then
						owned = true
						break
					end
				end
			end
			if owned then
				key = current
			end
		end
		key = key or InstanceWorld.pickInstance(player, target.instanceKind, target.subareaId)
	elseif isAreaKind(target.kind) and target.subareaId then
		key = InstanceWorld.pickInstance(player, target.kind, target.subareaId)
	end
	return key
end

--- Safe city/hub destination + instance id (no bind).
local function resolveSafeCity(player)
	local dest = InstanceWorld.rescuePos(player)
	local target = InstanceWorld.classify(dest)
	local instanceId = instanceIdForTarget(target, player)
	if instanceId then
		return dest, instanceId
	end
	local area = InstanceWorld.cityForTown(player:getTown())
	if not target.kind or target.kind == "stay" or target.kind == "blocked" or target.kind == "hunt" then
		if area and area.center then
			dest = Position(area.center.x, area.center.y, area.center.z)
		else
			dest = Position(32369, 32241, 7)
		end
	end
	local kind, subareaId = InstanceWorld.areaIdentity(area)
	if not kind then
		return dest, nil
	end
	return dest, InstanceWorld.pickInstance(player, kind, subareaId)
end

local function isGodPlayer(player)
	return PzTeleport.isGod(player)
end

local function liveHuntSession(player)
	if not player then
		return nil
	end
	local session = ExpeditionManager.getSessionByPlayer(player)
	if session and session.state ~= "ended" and ExpeditionInstance.isLive(session.instance) then
		return session
	end
	return nil
end

--- Live private expedition session for an engine instance id (not ended).
local function livePrivateSessionById(instanceId)
	instanceId = Instance.normalize(instanceId)
	if not Instance.isPrivate(instanceId) then
		return nil
	end
	local byInst = ExpeditionManager.getSessionByInstanceId(instanceId)
	if byInst and byInst.state ~= "ended" then
		return byInst
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
	return livePrivateSessionById(engineId)
end

--- Delayed leave when Lua/engine travel exits a private hunt into city/hub.
--- Only runs while the player is still on the private hunt id (no half-rebind).
local function scheduleDelayedHuntLeave(player, huntInstanceId)
	if not player then
		return
	end
	if InstanceWorld._suppressHuntLeave[player:getId()] then
		return
	end
	if not ExpeditionManager.isInExpedition(player) then
		return
	end
	local pid = player:getId()
	addEvent(function()
		local p = Player(pid)
		if not p then
			return
		end
		if InstanceWorld._suppressHuntLeave[pid] then
			return
		end
		local live = ExpeditionManager.getSessionByPlayer(p)
		local liveId = live and live.instance and live.instance.instanceId or nil
		if not liveId or liveId ~= huntInstanceId then
			return
		end
		-- Still on the private hold: leave must teleport home (never skipTeleport).
		-- Premature city rebind is no longer done in onEngineTravel for hunt sessions.
		if p:getInstanceId() ~= huntInstanceId then
			return
		end
		ExpeditionManager.leave(p, { silent = true, skipTeleport = false })
	end, 50)
end

--- Resolve bind target for travel without applying it.
--- Returns ok, bindId, scheduleLeave, current, kind
local function planTravelBind(creature, destPos)
	local player = asPlayer(creature)
	local current = Instance.of(creature)
	local session = player and huntSessionFor(player, current) or nil

	-- Live private hunt: stay on the private id inside the fence. Never city-rebind
	-- on shared XY (classify prefers city). Leaving the fence is blocked;
	-- intentional leave uses exitToOpenWorld / bindOpenWorld with _skipEngineTravel.
	if session and ExpeditionInstance.isLive(session.instance) then
		if ExpeditionInstance.contains(session.instance, destPos) then
			return true, session.instance.instanceId, false, current, "session"
		end
		return false, nil, false, current, "blocked"
	end

	local target = InstanceWorld.classify(destPos)
	if target.kind == "blocked" then
		return false, nil, false, current, "blocked"
	end

	local bindId = nil
	local scheduleLeave = false

	if target.kind == "stay" then
		return true, bindId, false, current, "stay"
	end

	-- Unscheduled hunt dest: stay on the current instance (HUD starts the private copy).
	if isPublicBindKind(target.kind) then
		bindId = instanceIdForTarget(target, player)
	end

	return true, bindId, scheduleLeave, current, target.kind
end

-- Teleports that keep the current city/hub id must land inside its walk
-- fence, or the player is stuck (e.g. a ladder just past the mask edge: the trapdoor
-- back down is outside too). Private ids are left to the session checks above.
local function strandsOutsideFence(creature, current, destPos)
	local player = asPlayer(creature)
	if not player or isGodPlayer(player) then
		return false
	end
	local kind = Instance.kind(current)
	if (not isAreaKind(kind) and kind ~= "hub") or Instance.isPrivate(current) then
		return false
	end
	return not Game.canWalkInstance(player, destPos)
end

--- Runs `fn` with engine travel routing suppressed (the caller already chose the instance).
--- The flag is cleared even when `fn` raises; returns fn's result as a boolean.
function InstanceWorld.withoutEngineTravel(fn)
	local previous = InstanceWorld._skipEngineTravel
	InstanceWorld._skipEngineTravel = true
	local ok, result = pcall(fn)
	InstanceWorld._skipEngineTravel = previous
	if not ok then
		logger.error("[InstanceWorld] travel failed: {}", tostring(result))
		return false
	end
	return result and true or false
end

--- creatureOnInstanceTravel: bind the layer `destPos` belongs to; false blocks the move.
function InstanceWorld.onEngineTravel(creature, destPos)
	if InstanceWorld._skipEngineTravel then
		return true
	end
	if not creature or not destPos then
		return true
	end

	local player = asPlayer(creature)
	local ok, bindId, scheduleLeave, current, kind = planTravelBind(creature, destPos)
	if not ok then
		return false
	end

	if (kind == "stay" or kind == "hunt") and strandsOutsideFence(creature, current, destPos) then
		player:sendCancelMessage("You cannot leave an instance area.")
		return false
	end

	if kind == "session" then
		bindCreature(creature, bindId)
		return true
	end

	if bindId and not isPublicBindKind(kind) then
		bindCreature(creature, bindId)
	end

	if kind == "stay" then
		return true
	end

	if Instance.isPrivate(current) and not isPublicBindKind(kind) then
		return true
	end

	if scheduleLeave and player then
		scheduleDelayedHuntLeave(player, current)
	end

	if isPublicBindKind(kind) then
		if bindId then
			bindCreature(creature, bindId)
		end
		return true
	end
	if kind == "hunt" then
		if bindId then
			bindCreature(creature, bindId)
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
	-- Resolve bind target without applying it, then teleportTo(..., instanceId)
	-- atomically. Avoid bind-then-teleport (client ghosts on the old instance).
	local player = asPlayer(creature)
	local ok, bindId, scheduleLeave, current = planTravelBind(creature, destPos)
	if not ok then
		return false
	end

	if scheduleLeave and player then
		scheduleDelayedHuntLeave(player, current)
	end

	return InstanceWorld.withoutEngineTravel(function()
		if bindId and player then
			return creature:teleportTo(destPos, false, bindId)
		end
		return creature:teleportTo(destPos)
	end)
end

function InstanceWorld.enterInstance(creature, instanceId, destPos)
	if not creature or not instanceId then
		return false
	end
	if destPos then
		-- Atomic bind+move — do not call setInstanceId again afterwards.
		return InstanceWorld.withoutEngineTravel(function()
			return creature:teleportTo(destPos, false, instanceId)
		end)
	end
	-- Same-tile bind only when no destination (engine teleport refuses identical XY/Z).
	bindCreature(creature, instanceId)
	return true
end

function InstanceWorld.canWalk(creature, destPos)
	return Game.canWalkInstance(creature, destPos) and true or false
end

--- Block creature drags/pushes that would leave instance occupancy.
function InstanceWorld.canMoveCreature(pusher, creature, _fromPos, toPos)
	if not creature or not toPos then
		return true
	end
	if not InstanceWorld.canWalk(creature, toPos) then
		return false
	end
	if pusher and pusher ~= creature then
		local pusherPos = pusher:getPosition()
		if pusherPos and not InstanceWorld.canWalk(pusher, pusherPos) then
			return false
		end
	end
	return true
end

function InstanceWorld.describeCurrent(player)
	if not player then
		return nil
	end
	local engineId = Instance.of(player)
	if Instance.isWorld(engineId) then
		return nil
	end
	-- Identity protocol: {kind, subareaId, channel} straight from the engine key; only the
	-- display name is looked up per kind.
	local parsed = Instance.parse(engineId)
	local desc = {
		subareaId = parsed.subareaId,
		kind = parsed.kind,
		key = parsed.key,
		channel = parsed.channel,
	}
	if parsed.kind == "hub" then
		local hub = InstanceWorld.hubs[1]
		desc.name = (hub and hub.name) or "Adventurers' Guild"
		desc.bounds = aabbAround(hub and hub.center or nil, InstanceWorld.HUB_WALK_RADIUS)
		return desc
	end
	-- The subarea's own name ("Darashia City"); catalog city rows carry the CIP city
	-- grouping ("Northern Darama"), which is only a fallback.
	if parsed.kind == "city" then
		local city = InstanceWorld.citiesBySubareaId[parsed.subareaId]
		desc.name = InstanceWorld.subareaName(parsed.subareaId) or (city and city.name) or ("City " .. tostring(parsed.subareaId))
		return desc
	end
	-- Before the hunt session: a player can still hold a live expedition session while in a lobby room.
	if parsed.kind == "lobby" then
		return LobbyInstance.describe(player) or desc
	end
	local session = huntSessionFor(player, engineId)
	if session and session.instance then
		desc.name = (session.catalog and session.catalog.name) or session.displayName or session.raidName or "Hunt"
		return desc
	end
	desc.name = InstanceWorld.subareaName(parsed.subareaId) or desc.name
	return desc
end

function InstanceWorld.sendBounds(player, force)
	if not player then
		return false
	end
	local desc = InstanceWorld.describeCurrent(player)
	local pid = player:getId() or 0
	local cacheKey = desc and desc.key or ""
	if not force and InstanceWorld._boundsSent[pid] == cacheKey then
		return true
	end
	InstanceWorld._boundsSent[pid] = cacheKey
	local sent = ExpeditionProtocol.sendInstanceBounds(player, desc)
	-- Same moment the client learns the instance: area ambience, music, and climate.
	if PlaceSound then
		PlaceSound.send(player, desc)
	end
	if PlaceClimate then
		PlaceClimate.send(player, desc)
	end
	return sent
end

local function isLobbyPosition(pos)
	return LobbyInstance ~= nil and LobbyInstance.isLobbyPosition(pos)
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

local function sameTile(a, b)
	return a and b and a.x == b.x and a.y == b.y and a.z == b.z
end

--- City / hub tile that is not also a hunt footprint.
--- Open-world instance binds are only legal on these tiles.
function InstanceWorld.isTownOnlyPos(pos)
	pos = asWorldPos(pos)
	if not pos then
		return false
	end
	local target = InstanceWorld.classify(pos)
	if not isAreaKind(target.kind) and target.kind ~= "hub" then
		return false
	end
	if target.kind ~= "hub" and InstanceWorld.isHuntTile(pos) then
		return false
	end
	return true
end

--- Newhaven (CIP hunt 514) and Targuna sit outside city occupancy masks.
local function isStarterIslandTown(town)
	if not town then
		return false
	end
	local id = town:getId()
	return id == TOWNS_LIST.NEWHAVEN or id == TOWNS_LIST.TARGUNA
end

local function validRescueDest(pos, player)
	if InstanceWorld.isTownOnlyPos(pos) then
		return true
	end
	-- Keep starters on their island temple instead of falling through to Thais.
	if player and isStarterIslandTown(player:getTown()) then
		local temple = player:getTown():getTemplePosition()
		if temple and pos and pos.x == temple.x and pos.y == temple.y and pos.z == temple.z then
			return true
		end
	end
	return false
end

function InstanceWorld.rescuePos(player)
	local dest = nil
	dest = ExpeditionManager.loadReturnPos(player)
	if not validRescueDest(dest, player) then
		local town = player:getTown()
		if town then
			dest = town:getTemplePosition()
		end
	end
	if not validRescueDest(dest, player) then
		local city = InstanceWorld.cityForTown(player:getTown())
		if city and city.center then
			dest = Position(city.center.x, city.center.y, city.center.z)
		end
	end
	if not validRescueDest(dest, player) then
		dest = Position(32369, 32241, 7)
	end
	return dest
end

local function resolveTownOnlyDest(player, preferred)
	local dest = asWorldPos(preferred)
	if InstanceWorld.isTownOnlyPos(dest) then
		return dest
	end
	-- Newhaven/Targuna temples and village tiles are hunt/wild footprints, not city masks.
	local town = player and player:getTown()
	if isStarterIslandTown(town) then
		if dest then
			local target = InstanceWorld.classify(dest)
			if target and (target.kind == "open" or isPublicBindKind(target.kind)) then
				return dest
			end
		end
		local temple = town:getTemplePosition()
		if temple then
			return temple
		end
	end
	dest = InstanceWorld.rescuePos(player)
	if InstanceWorld.isTownOnlyPos(dest) or validRescueDest(dest, player) then
		return dest
	end
	local area = InstanceWorld.cityForTown(player:getTown())
	if area and area.center then
		dest = Position(area.center.x, area.center.y, area.center.z)
		if InstanceWorld.isTownOnlyPos(dest) then
			return dest
		end
	end
	return Position(32369, 32241, 7)
end

--- Atomic open-world place bind: city/hub instance only on town-only XY.
--- Never setInstanceId alone while standing on a hunt footprint.
--- Open-world destination and instance key for `destPos` (safe city when it has none).
--- Returns nil when no open-world instance can be resolved.
function InstanceWorld.openWorldTarget(player, destPos)
	destPos = resolveTownOnlyDest(player, destPos)
	local bindId = instanceIdForTarget(InstanceWorld.classify(destPos), player)
	if not bindId then
		destPos, bindId = resolveSafeCity(player)
		destPos = resolveTownOnlyDest(player, destPos)
		bindId = instanceIdForTarget(InstanceWorld.classify(destPos), player)
		if not bindId then
			destPos, bindId = resolveSafeCity(player)
		end
	end
	if not bindId then
		return nil
	end
	return destPos, bindId
end

function InstanceWorld.bindOpenWorld(player, destPos)
	if not player then
		return false
	end
	local bindId
	destPos, bindId = InstanceWorld.openWorldTarget(player, destPos)
	if not bindId then
		return false
	end

	local cur = player:getPosition()
	-- Same-tile setInstanceId is only legal when already on a town-only tile.
	if sameTile(cur, destPos) and InstanceWorld.isTownOnlyPos(cur) then
		bindCreature(player, bindId)
		return true
	end

	if not player:getTile() then
		return false
	end

	local ok = InstanceWorld.withoutEngineTravel(function()
		return player:teleportTo(destPos, false, bindId)
	end)
	if not ok then
		destPos = resolveTownOnlyDest(player, nil)
		local safeTarget = InstanceWorld.classify(destPos)
		bindId = instanceIdForTarget(safeTarget, player)
		if not bindId then
			destPos, bindId = resolveSafeCity(player)
		end
		cur = player:getPosition()
		if InstanceWorld.isTownOnlyPos(cur) and sameTile(cur, destPos) then
			if bindId then
				bindCreature(player, bindId)
			end
			ok = true
		elseif bindId and player:getTile() and not sameTile(cur, destPos) then
			ok = InstanceWorld.withoutEngineTravel(function()
				return player:teleportTo(destPos, false, bindId)
			end)
		else
			-- Never bind-only onto a hunt footprint.
			ok = false
		end
	end
	return ok
end

--- Leave a private hunt/raid/lobby instance for city/hub.
function InstanceWorld.exitToOpenWorld(player, destPos)
	return InstanceWorld.bindOpenWorld(player, destPos)
end

--- A leftover private instance or expedition marker after the in-memory session is gone.
function InstanceWorld.isStrandedExpedition(player, pos)
	if not player then
		return false
	end
	if liveHuntSession(player) then
		return false
	end
	pos = asWorldPos(pos)
	if isLobbyPosition(pos) then
		return false
	end
	local instanceId = Instance.of(player)
	if Instance.isPrivate(instanceId) then
		-- Headless restore / deploy can place onto a live private id before the
		-- player is registered as a session member — not stranded.
		if livePrivateSessionById(instanceId) then
			return false
		end
		return true
	end
	-- Logged out inside a private hunt/raid whose session is gone (the engine did not restore it).
	local record = InstanceWorld.loginRecord(player)
	if record and record.private and (record.kind == "hunt" or record.kind == "raid" or record.kind == "soulpit") then
		return true
	end
	-- Hunt tiles alone are not stranding: open-world hunting grounds are public layers.
	return ExpeditionConfig ~= nil and player:getStorageValue(ExpeditionConfig.STORAGE_ACTIVE) == 1
end

function InstanceWorld.shouldRescue(player)
	if not player then
		return false
	end
	if ExpeditionManager.hasPendingRestore(player) then
		return false
	end
	-- Waiting / starting sessions, or already placed on a live private hunt id
	-- (restore/deploy before member register), must not be yanked to temple.
	local session = liveHuntSession(player)
	if session and (not session.entered or session.starting) then
		return false
	end
	local engineId = Instance.of(player)
	if livePrivateSessionById(engineId) then
		return false
	end
	local pos = player:getPosition()
	if InstanceWorld.isStrandedExpedition(player, pos) then
		return true
	end
	if isLobbyPosition(pos) then
		return false
	end
	if pos and not InstanceWorld.canWalk(player, pos) then
		if isGodPlayer(player) and Instance.isPrivate(engineId) then
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
	ExpeditionManager.clearActiveFlag(player)
	ExpeditionManager.clearAreaEffects(player)
	player:setIdleCombat(false)
	if not player:getTile() then
		return false
	end
	local inLobby = false
	if Alts.isRealUiClient(player) then
		local record = LobbyManager.ensureForPlayer(player)
		inLobby = record ~= nil and LobbyInstance.enterNow(player, record, {}) == true
	end
	local ok = inLobby or InstanceWorld.bindOpenWorld(player, nil)
	if ok then
		local now = player:getPosition()
		if now then
			now:sendMagicEffect(CONST_ME_TELEPORT)
		end
		player:sendTextMessage(MESSAGE_EVENT_ADVANCE, "Your expedition was interrupted. You were returned to safety.")
	end
	return ok
end

--- playerOnInstanceBind: login / headless spawn, before the engine's open-world fallbacks.
function InstanceWorld.bindLogin(player, loginPos)
	if not player then
		return
	end
	local session = liveHuntSession(player)
	if session and ExpeditionInstance.isLive(session.instance) then
		bindCreature(player, session.instance.instanceId)
		return
	end
	-- Placed already on a live private hunt id (restore/deploy before member register).
	local byInst = livePrivateSessionById(Instance.of(player))
	if byInst and ExpeditionInstance.isLive(byInst.instance) then
		bindCreature(player, byInst.instance.instanceId)
		return
	end
	if LobbyInstance.restoreOnLogin(player) then
		return
	end
	local pos = asWorldPos(loginPos) or player:getPosition()
	-- Bind city/hub/subarea region in place. Hunt-footprint overlap is fine for login —
	-- the player is already standing there. Temple yank belongs to rescueIfStranded.
	local target = pos and InstanceWorld.classify(pos) or nil
	if target and isPublicBindKind(target.kind) then
		local bindId = instanceIdForTarget(target, player)
		if bindId then
			bindCreature(player, bindId)
			return
		end
	end
	-- Non-city open world / hunt / stay: leave position alone.
	-- InstanceWorld.rescueIfStranded (login) owns temple return when actually stranded.
end

--- NPC spawns resolve their city/hub instance at creation (C++ area fences);
--- this only reports the split so a missing fence shows up in the startup log.
function InstanceWorld.logNpcInstances()
	local area, open = 0, 0
	for _, npc in ipairs(Game.getNpcs()) do
		if npc then
			if not Instance.isWorld(npc:getInstanceId()) then
				area = area + 1
			else
				open = open + 1
			end
		end
	end
	logger.info("[InstanceWorld] NPCs born in city/hub instances: {} (open world: {})", area, open)
end

local FORGE_FIENDISH = 2
local FORGE_INFLUENCED = 1

local function countWorldSpawnSlots()
	local mapName = configManager.getString(configKeys.MAP_NAME)
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
	local n = tonumber(configManager.getNumber(key))
	if n and n > 0 then
		return n
	end
	return fallback
end

--- Match open-world forge density: `forgeFiendishLimit` / world spawn slots (not the
--- server-wide cap dumped onto the handful of hunt creatures).
function InstanceWorld.applyOpenWorldForge(monster)
	if not monster or not monster:isForgeable() then
		return monster
	end
	local population = tonumber(InstanceWorld.worldSpawnSlots) or 0
	if population < 1 then
		return monster
	end
	local fiendishLimit = forgeLimit(configKeys.FORGE_FIENDISH_CREATURES_LIMIT, 4)
	local influencedLimit = forgeLimit(configKeys.FORGE_INFLUENCED_CREATURES_LIMIT, 300)
	local roll = math.random()
	local fiendishChance = fiendishLimit / population
	if roll < fiendishChance then
		monster:setMonsterForgeClassification(FORGE_FIENDISH)
		monster:configureForgeSystem()
	elseif roll < fiendishChance + (influencedLimit / population) then
		monster:setMonsterForgeClassification(FORGE_INFLUENCED)
		monster:configureForgeSystem()
	end
	return monster
end

function InstanceWorld.onStartup()
	InstanceWorld.worldSpawnSlots = countWorldSpawnSlots()
	if InstanceWorld.worldSpawnSlots > 0 then
		logger.info(
			"[InstanceWorld] open-world forge rate uses {} spawn slots (fiendish {}, influenced {})",
			InstanceWorld.worldSpawnSlots,
			forgeLimit(configKeys.FORGE_FIENDISH_CREATURES_LIMIT, 4),
			forgeLimit(configKeys.FORGE_INFLUENCED_CREATURES_LIMIT, 300)
		)
	else
		logger.warn("[InstanceWorld] world-monster.xml spawn count is 0; hunt forge rolls disabled")
	end
	if Game.isSubareaInstancesEnabled() then
		logger.info("[InstanceWorld] open-world spawns start per subarea layer on first player")
	end
	InstanceWorld.logNpcInstances()
end
