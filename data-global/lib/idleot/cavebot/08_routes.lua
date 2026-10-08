-- Routes for open-world runs. A catalog hunt covering the anchor's tile ships an
-- optimized route ("catalog"); it is used when the anchor can walk to every waypoint
-- on this layer (closed doors and the instance fence block). Otherwise a route is
-- generated ("generated") with the hunt-generation builder (CaveRoute) over the
-- anchor's walk component (Game.walkGrid) and the layer's live spawns.
--
-- Open-world runs never walk a catalog entry leg: the party is already inside, so
-- the walk starts at the waypoint nearest to the anchor (Cavebot.resume).

CavebotRoutes = CavebotRoutes or {}

-- Retry a component that had no route after this long (spawns may have been dead).
local RETRY_MS = 60000
-- Catalog route validation grid: waypoint bounding box grown by this many tiles.
local CATALOG_MARGIN = 8

-- Per layer (blocking items and doors differ between instances):
--   catalog[hunt id] -> { { grid, ok }, ... } (one per walk component that checked it)
--   generated[z] -> { { grid, route, failedAt }, ... }
local caches = {}

local function cacheOf(instanceKey)
	local cache = caches[instanceKey]
	if not cache then
		cache = { catalog = {}, generated = {} }
		caches[instanceKey] = cache
	end
	return cache
end

--- Drop the routes and walk grids cached for `instanceKey` (the layer was released).
function CavebotRoutes.forget(instanceKey)
	caches[instanceKey] = nil
end

IdleEvents.on("instance.released", CavebotRoutes.forget)

local nowMs = CombatGeo.nowMs

local function runtimeRoute(waypoints, lure)
	return {
		lure = math.max(1, math.floor(tonumber(lure) or 1)),
		entry = {},
		waypoints = waypoints,
		stationary = #waypoints <= 1,
	}
end

local function findIn(list, pos)
	for _, entry in ipairs(list or {}) do
		if entry.grid:getZ() == pos.z and entry.grid:contains(pos.x, pos.y) then
			return entry
		end
	end
	return nil
end

--- Walk component around `pos` on the layer `instanceKey` (fenced to its subarea).
local function walkGrid(pos, instanceKey, bounds)
	local opts = {
		instance = instanceKey,
		subareaId = Instance.subareaId(instanceKey) or 0,
		cap = CavebotConfig.WALK_GRID_CAP,
	}
	for k, v in pairs(bounds or {}) do
		opts[k] = v
	end
	return Game.walkGrid(Position(pos.x, pos.y, pos.z), opts)
end

-- ---------------------------------------------------------------------------
-- Catalog insight
-- ---------------------------------------------------------------------------

--- Waypoints of `route` on floor z, or nil when the route is not on that floor.
local function floorWaypoints(route, z)
	local out = {}
	for _, w in ipairs(route.waypoints) do
		if w.z ~= z then
			return nil
		end
		out[#out + 1] = { x = w.x, y = w.y, z = w.z, hold = w.hold }
	end
	return #out > 0 and out or nil
end

--- The anchor's walk component (bounded to the route's box) holds every waypoint.
local function catalogWalkable(hunt, waypoints, anchorPos, instanceKey)
	local catalog = cacheOf(instanceKey).catalog
	local checks = catalog[hunt.id]
	local cached = findIn(checks, anchorPos)
	if cached then
		return cached.ok
	end
	local minX, minY, maxX, maxY = anchorPos.x, anchorPos.y, anchorPos.x, anchorPos.y
	for _, w in ipairs(waypoints) do
		minX, minY = math.min(minX, w.x), math.min(minY, w.y)
		maxX, maxY = math.max(maxX, w.x), math.max(maxY, w.y)
	end
	local grid = walkGrid(anchorPos, instanceKey, {
		minX = minX - CATALOG_MARGIN,
		minY = minY - CATALOG_MARGIN,
		maxX = maxX + CATALOG_MARGIN,
		maxY = maxY + CATALOG_MARGIN,
	})
	if not grid then
		return false
	end
	local ok = true
	for _, w in ipairs(waypoints) do
		if not grid:contains(w.x, w.y) then
			ok = false
			break
		end
	end
	if not checks then
		checks = {}
		catalog[hunt.id] = checks
	end
	checks[#checks + 1] = { grid = grid, ok = ok }
	if not ok then
		logger.info("[Cavebot] catalog route of '{}' is not walkable on {} (doors / fence): generating", tostring(hunt.name or hunt.id), instanceKey)
	end
	return ok
end

local function catalogRoute(anchor, instanceKey)
	local pos = anchor:getPosition()
	local desc = { kind = Instance.kind(instanceKey), key = instanceKey, subareaId = Instance.subareaId(instanceKey) }
	local hunt = ExpeditionProtocol and ExpeditionProtocol.openWorldHunt and ExpeditionProtocol.openWorldHunt(anchor, desc)
	local route = hunt and ExpeditionConfig.caveRoute(hunt)
	local waypoints = route and floorWaypoints(route, pos.z)
	if not waypoints or not catalogWalkable(hunt, waypoints, pos, instanceKey) then
		return nil
	end
	return runtimeRoute(waypoints, route.lure), hunt.name or tostring(hunt.id)
end

-- ---------------------------------------------------------------------------
-- Generated
-- ---------------------------------------------------------------------------

local function nearGrid(grid, pos)
	if grid:contains(pos.x, pos.y) then
		return true
	end
	for _, off in ipairs(CombatGeo.NEIGHBOUR_OFFSETS) do
		if grid:contains(pos.x + off[1], pos.y + off[2]) then
			return true
		end
	end
	return false
end

--- Spawn tiles of the layer's live monsters (not summons, worth experience) in or
--- next to the component.
local function componentSpawns(grid, instanceKey)
	local spawns, z = {}, grid:getZ()
	for _, monster in ipairs(Game.getMonsters()) do
		if monster:getInstanceId() == instanceKey and not monster:getMaster() then
			local mType = monster:getType()
			local pos = monster:getSpawnPosition()
			if pos and pos.z == z and mType and mType:experience() > 0 and nearGrid(grid, pos) then
				spawns[#spawns + 1] = { x = pos.x, y = pos.y, name = monster:getName() }
			end
		end
	end
	return spawns
end

local function distinctTiles(spawns)
	local seen, n = {}, 0
	for _, s in ipairs(spawns) do
		local k = s.x * 65536 + s.y
		if not seen[k] then
			seen[k] = true
			n = n + 1
		end
	end
	return n
end

local function buildGenerated(grid, instanceKey)
	local spawns = componentSpawns(grid, instanceKey)
	if distinctTiles(spawns) < CavebotConfig.GENERATED_MIN_SPAWNS then
		return nil
	end
	local built = CaveRoute.build({
		spawns = spawns,
		z = grid:getZ(),
		standable = function(x, y)
			return grid:contains(x, y)
		end,
		bfs = function(x, y, maxDepth, targets)
			return grid:bfs(x, y, maxDepth, targets)
		end,
	})
	if not built then
		return nil
	end
	local waypoints = {}
	for i, w in ipairs(built.waypoints) do
		waypoints[i] = { x = w.x, y = w.y, z = w.z, hold = w.hold == true }
	end
	return runtimeRoute(waypoints, built.lure)
end

local function generatedRoute(anchor, instanceKey)
	local pos = anchor:getPosition()
	local generated = cacheOf(instanceKey).generated
	local list = generated[pos.z]
	local entry = findIn(list, pos)
	if entry and (entry.route or nowMs() - entry.failedAt < RETRY_MS) then
		return entry.route
	end
	local grid = entry and entry.grid or walkGrid(pos, instanceKey)
	if not grid then
		return nil
	end
	local route = buildGenerated(grid, instanceKey)
	if not entry then
		entry = { grid = grid }
		list = list or {}
		list[#list + 1] = entry
		generated[pos.z] = list
	end
	entry.route, entry.failedAt = route, nowMs()
	if route then
		logger.info("[Cavebot] generated route on {} z={}: {} waypoints, lure {}", instanceKey, pos.z, #route.waypoints, route.lure)
	end
	return route
end

--- Route for an open-world run anchored by `anchor` on `instanceKey`.
--- Returns route, source ("catalog" | "generated"), hunt name; nil when none.
function CavebotRoutes.resolve(anchor, instanceKey)
	local route, name = catalogRoute(anchor, instanceKey)
	if route then
		return route, "catalog", name
	end
	route = generatedRoute(anchor, instanceKey)
	if route then
		return route, "generated", nil
	end
	return nil
end
