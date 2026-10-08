-- CaveBot-style hunt route: one closed walk over a hunt's spawn clusters. Single
-- implementation shared by the runtime (open-world routes, cavebot/08_routes.lua) and
-- hunt generation, which loads this file and 01_anchor_spot.lua through lupa
-- (packages/asset-pipeline features/expedition/crystal/lua_cave_route.py).
-- Pure Lua (5.1 - 5.4): no engine API, tiles come through `env` callbacks.
--
-- A route is a closed walk, not a simple cycle: tiles may repeat, so a hunt can be a
-- circle, a dead-end leg walked in and back on the same corridor, or any mix. The
-- cavebot walks it continuously and only fights at `hold` tiles.
--
-- 1. Cluster spawns greedily by walk distance (densest spawn first).
-- 2. One hold tile per cluster: the best AnchorSpot tile near its densest spawn.
-- 3. Merge clusters whose holds are within HOLD_MIN_GAP walk steps.
-- 4. Order holds: nearest neighbour from the hold closest to the entry, then 2-opt on
--    walk distances. Expanding every hop into its shortest walk turns a dead-end
--    cluster into an in-and-back leg.
-- 5. Drop the cluster with the worst spawns-per-detour while the lap is too long.
-- 6. Waypoints: the walk thinned by WAYPOINT_GAP, plus holds and dead-end turn tiles.
-- 7. Lure: median spawn tiles seen along LURE_WALK-step stretches.
--
-- env = {
--   spawns = { { x, y, name }, ... },
--   standable = function(x, y) -> bool,   -- walkable tile of the route's component
--   z = floor,
--   entry = { x, y, z },                  -- optional: where the party arrives
--   teamFits = function(x, y) -> bool,    -- optional hold tiebreak
--   bfs = function(x, y, maxDepth, targetKeys) -> dist, parent, -- optional (engine
--         WalkGrid:bfs); keyed by CombatGeo.tileKey, same neighbour order
--   lapMax, maxClusters,                  -- optional (LAP_MAX_STEPS, MAX_CLUSTERS)
-- }

CaveRoute = CaveRoute or {}

-- Spawns within this many walk steps of a cluster's seed join it.
CaveRoute.CLUSTER_WALK = 6
-- A cluster's hold is the best AnchorSpot tile within this many steps of its densest spawn.
CaveRoute.VISIT_RADIUS = 4
-- Holds closer than this (walk steps) merge: two screens apart.
CaveRoute.HOLD_MIN_GAP = 14
CaveRoute.MAX_CLUSTERS = 24
-- Clusters are dropped (worst spawns per detour first) while the lap is longer.
CaveRoute.LAP_MAX_STEPS = 400
-- One waypoint every this many walk steps (plus holds and turn tiles).
CaveRoute.WAYPOINT_GAP = 6
-- Lure: spawns seen along stretches of this many walk steps.
CaveRoute.LURE_WALK = 36
CaveRoute.VIEWPORT_X = 7
CaveRoute.VIEWPORT_Y = 5
-- Hold tiebreaks on top of the AnchorSpot score (one AnchorSpot ring tile is 250).
CaveRoute.HOLD_SPAWN_TILE_PENALTY = 2
CaveRoute.HOLD_TEAM_FIT_BONUS = 2

local UNREACHABLE = 1000000

-- Same order as AnchorSpot and the engine WalkGrid.
local NEIGHBOURS = CombatGeo.NEIGHBOUR_OFFSETS
local tileKey, keyXY = CombatGeo.tileKey, CombatGeo.keyXY

local floor = math.floor

--- Pure Lua 8-connected walk distances and parents from (sx, sy) over `standable`
--- (the start always counts). With `targets` (keys) it stops once every target other
--- than the start was reached.
function CaveRoute.makeBfs(standable)
	return function(sx, sy, maxDepth, targets)
		local start = tileKey(sx, sy)
		local dist, parent = { [start] = 0 }, {}
		local remaining, left
		if targets and #targets > 0 then
			remaining, left = {}, 0
			for _, k in ipairs(targets) do
				if k ~= start and not remaining[k] then
					remaining[k] = true
					left = left + 1
				end
			end
		end
		local qx, qy, head, tail = { sx }, { sy }, 1, 1
		while head <= tail do
			local x, y = qx[head], qy[head]
			head = head + 1
			local here = tileKey(x, y)
			local d = dist[here]
			if not maxDepth or maxDepth < 0 or d < maxDepth then
				for _, off in ipairs(NEIGHBOURS) do
					local nx, ny = x + off[1], y + off[2]
					local k = tileKey(nx, ny)
					if dist[k] == nil and standable(nx, ny) then
						dist[k] = d + 1
						parent[k] = here
						tail = tail + 1
						qx[tail], qy[tail] = nx, ny
						if remaining then
							if remaining[k] then
								remaining[k] = nil
								left = left - 1
							end
							if left == 0 then
								return dist, parent
							end
						end
					end
				end
			end
		end
		return dist, parent
	end
end

--- Keys from `start` to `goal` over a parent tree.
local function pathTo(parent, start, goal)
	local out = { goal }
	while out[#out] ~= start do
		out[#out + 1] = parent[out[#out]]
	end
	local n = #out
	for i = 1, floor(n / 2) do
		out[i], out[n - i + 1] = out[n - i + 1], out[i]
	end
	return out
end

local function spawnXY(spawn)
	return floor(tonumber(spawn.x) or 0), floor(tonumber(spawn.y) or 0)
end

--- Monsters the spawns put on the map: entries sharing a tile spawn one.
local function slotsOf(spawns, idxs)
	local seen, n = {}, 0
	for _, i in ipairs(idxs) do
		local k = tileKey(spawnXY(spawns[i]))
		if not seen[k] then
			seen[k] = true
			n = n + 1
		end
	end
	return n
end

--- The spawn tile, or its first standable neighbour (spawns can sit on blockers).
local function walkOrigin(x, y, standable)
	if standable(x, y) then
		return x, y
	end
	for _, off in ipairs(NEIGHBOURS) do
		if standable(x + off[1], y + off[2]) then
			return x + off[1], y + off[2]
		end
	end
	return nil
end

--- Greedy walk-distance clusters, densest spawn first (deterministic). Returns lists
--- of spawn indices.
function CaveRoute.clusterSpawns(spawns, standable, bfs, walk)
	walk = walk or CaveRoute.CLUSTER_WALK
	local sorted = {}
	for i = 1, #spawns do
		sorted[i] = i
	end
	table.sort(sorted, function(a, b)
		local ax, ay = spawnXY(spawns[a])
		local bx, by = spawnXY(spawns[b])
		if ax ~= bx then
			return ax < bx
		end
		if ay ~= by then
			return ay < by
		end
		local an, bn = tostring(spawns[a].name or ""), tostring(spawns[b].name or "")
		if an ~= bn then
			return an < bn
		end
		return a < b
	end)
	local origins = {}
	for _, si in ipairs(sorted) do
		local x, y = spawnXY(spawns[si])
		local ox, oy = walkOrigin(x, y, standable)
		if ox then
			origins[#origins + 1] = { spawn = si, x = ox, y = oy }
		end
	end
	local byOrigin = {}
	for i, o in ipairs(origins) do
		local k = tileKey(o.x, o.y)
		local list = byOrigin[k]
		if not list then
			list = {}
			byOrigin[k] = list
		end
		list[#list + 1] = i
	end

	local reach, slots = {}, {}
	for i, o in ipairs(origins) do
		local dist = bfs(o.x, o.y, walk)
		local r = {}
		for k in pairs(dist) do
			local list = byOrigin[k]
			if list then
				for _, j in ipairs(list) do
					r[#r + 1] = j
				end
			end
		end
		table.sort(r)
		reach[i] = r
		local idxs = {}
		for n, j in ipairs(r) do
			idxs[n] = origins[j].spawn
		end
		slots[i] = slotsOf(spawns, idxs)
	end

	local order = {}
	for i = 1, #origins do
		order[i] = i
	end
	table.sort(order, function(a, b)
		if slots[a] ~= slots[b] then
			return slots[a] > slots[b]
		end
		local oa, ob = origins[a], origins[b]
		if oa.x ~= ob.x then
			return oa.x < ob.x
		end
		if oa.y ~= ob.y then
			return oa.y < ob.y
		end
		return a < b
	end)
	local taken, clusters = {}, {}
	for _, i in ipairs(order) do
		if not taken[i] then
			local members = {}
			for _, j in ipairs(reach[i]) do
				if not taken[j] then
					members[#members + 1] = j
				end
			end
			for _, j in ipairs(members) do
				taken[j] = true
			end
			taken[i] = true
			local cluster = {}
			for n, j in ipairs(members) do
				cluster[n] = origins[j].spawn
			end
			if #cluster == 0 then
				cluster[1] = origins[i].spawn
			end
			clusters[#clusters + 1] = cluster
		end
	end
	return clusters
end

--- Hold tile within VISIT_RADIUS steps of the cluster's densest spawn: the best
--- AnchorSpot score, with off-spawn tiles and team fit as tiebreaks.
local function pickVisit(spawns, cluster, standable, teamFits)
	local spawnTiles = {}
	for _, i in ipairs(cluster) do
		spawnTiles[tileKey(spawnXY(spawns[i]))] = true
	end
	local fx, fy = spawnXY(spawns[cluster[1]])
	local sx, sy = walkOrigin(fx, fy, standable)
	if not sx then
		return nil
	end
	local env = {
		standable = standable,
		adjust = function(x, y)
			local bonus = 0
			if spawnTiles[tileKey(x, y)] then
				bonus = bonus - CaveRoute.HOLD_SPAWN_TILE_PENALTY
			end
			if teamFits and teamFits(x, y) then
				bonus = bonus + CaveRoute.HOLD_TEAM_FIT_BONUS
			end
			return bonus
		end,
	}
	local ctx = AnchorSpot.context(env, AnchorSpot.DEFAULT_TEAM)
	return AnchorSpot.best(ctx, sx, sy, CaveRoute.VISIT_RADIUS)
end

--- Indices of clusters that keep their hold, densest first; a cluster whose hold is
--- within `gap` walk steps of a kept one merges its spawns into the nearest.
local function spaceHolds(spawns, clusters, d, gap)
	local slots, order = {}, {}
	for i, c in ipairs(clusters) do
		slots[i] = slotsOf(spawns, c.spawns)
		order[i] = i
	end
	table.sort(order, function(a, b)
		if slots[a] ~= slots[b] then
			return slots[a] > slots[b]
		end
		return a < b
	end)
	local kept = {}
	for _, i in ipairs(order) do
		local best
		for _, k in ipairs(kept) do
			if d[i][k] < gap and (not best or d[i][k] < d[i][best] or (d[i][k] == d[i][best] and k < best)) then
				best = k
			end
		end
		if best then
			local into = clusters[best].spawns
			for _, s in ipairs(clusters[i].spawns) do
				into[#into + 1] = s
			end
		else
			kept[#kept + 1] = i
		end
	end
	table.sort(kept)
	return kept
end

local function tourLength(tour, d)
	local n = #tour
	if n < 2 then
		return 0
	end
	local total = 0
	for i = 1, n do
		total = total + d[tour[i]][tour[i % n + 1]]
	end
	return total
end

--- Closed tour over `ids` from `start`: nearest neighbour, then 2-opt.
function CaveRoute.orderVisits(start, ids, d)
	local rest = {}
	for _, i in ipairs(ids) do
		if i ~= start then
			rest[#rest + 1] = i
		end
	end
	local tour = { start }
	while #rest > 0 do
		local here = tour[#tour]
		local bestPos
		for pos, j in ipairs(rest) do
			local b = bestPos and rest[bestPos]
			if not b or d[here][j] < d[here][b] or (d[here][j] == d[here][b] and j < b) then
				bestPos = pos
			end
		end
		tour[#tour + 1] = rest[bestPos]
		table.remove(rest, bestPos)
	end
	if #tour < 4 then
		return tour
	end
	local improved = true
	while improved do
		improved = false
		local n = #tour
		for i = 2, n - 1 do
			for k = i + 1, n do
				local a, b = tour[i - 1], tour[i]
				local c, e = tour[k], tour[k % n + 1]
				if d[a][c] + d[b][e] < d[a][b] + d[c][e] then
					local lo, hi = i, k
					while lo < hi do
						tour[lo], tour[hi] = tour[hi], tour[lo]
						lo, hi = lo + 1, hi - 1
					end
					improved = true
				end
			end
		end
	end
	return tour
end

local function pruneForLap(start, ids, weights, d, lapMax)
	local tour = CaveRoute.orderVisits(start, ids, d)
	while #tour > 1 and tourLength(tour, d) > lapMax do
		local n = #tour
		local worstRatio, worst
		for i = 2, n do
			local prev, cur, nxt = tour[i - 1], tour[i], tour[i % n + 1]
			local detour = d[prev][cur] + d[cur][nxt] - d[prev][nxt]
			local ratio = weights[cur] / math.max(1, detour)
			if not worst or ratio < worstRatio or (ratio == worstRatio and cur < worst) then
				worstRatio, worst = ratio, cur
			end
		end
		local rest = {}
		for _, i in ipairs(tour) do
			if i ~= worst then
				rest[#rest + 1] = i
			end
		end
		tour = CaveRoute.orderVisits(start, rest, d)
	end
	return tour
end

local function lureFromDensity(density)
	local n = density > 0 and floor(density) or 0
	return math.max(1, n)
end

--- Median spawn tiles seen along `walk`-step stretches (every `stride` steps) of the
--- closed walk `path` ({ { x, y }, ... }), at least 1.
function CaveRoute.lureAlongWalk(path, spawns, walk, stride)
	walk = walk or CaveRoute.LURE_WALK
	stride = math.max(1, stride or CaveRoute.WAYPOINT_GAP)
	local n = #path
	if n == 0 then
		return lureFromDensity(0)
	end
	local tiles, seenTile = {}, {}
	for _, s in ipairs(spawns) do
		local x, y = spawnXY(s)
		local k = tileKey(x, y)
		if not seenTile[k] then
			seenTile[k] = true
			tiles[#tiles + 1] = { x, y }
		end
	end
	local vx, vy = CaveRoute.VIEWPORT_X, CaveRoute.VIEWPORT_Y
	local seenAt = {}
	for i, p in ipairs(path) do
		local list = {}
		for t, tile in ipairs(tiles) do
			if math.abs(tile[1] - p[1]) <= vx and math.abs(tile[2] - p[2]) <= vy then
				list[#list + 1] = t
			end
		end
		seenAt[i] = list
	end
	local span = math.min(walk, n)
	local counts = {}
	for start = 0, n - 1, stride do
		local seen, c = {}, 0
		for k = 0, span - 1 do
			for _, t in ipairs(seenAt[(start + k) % n + 1]) do
				if not seen[t] then
					seen[t] = true
					c = c + 1
				end
			end
		end
		counts[#counts + 1] = c
	end
	table.sort(counts)
	local m = #counts
	local median
	if m % 2 == 1 then
		median = counts[(m + 1) / 2]
	else
		median = (counts[m / 2] + counts[m / 2 + 1]) / 2
	end
	return lureFromDensity(median)
end

--- Memoised `rawStandable` plus the coordinates of every probed tile (keys only
--- decode for 0 <= y < 65536).
local function probeCache(rawStandable)
	local cache, coords = {}, {}
	local function standable(x, y)
		local k = tileKey(x, y)
		local v = cache[k]
		if v == nil then
			v = rawStandable(x, y) == true
			cache[k] = v
			coords[k] = { x, y }
		end
		return v
	end
	local function xyOf(k)
		local c = coords[k]
		if c then
			return c[1], c[2]
		end
		return keyXY(k)
	end
	return standable, xyOf
end

--- Steps 1-2: spawn clusters (dense ones only when there are any), each with its hold
--- tile (`key`) and that tile's AnchorSpot ring; clusters sharing a hold collapse.
local function pickClusters(spawns, standable, bfs, teamFits, maxClusters)
	local groups = CaveRoute.clusterSpawns(spawns, standable, bfs)
	local dense = {}
	for _, g in ipairs(groups) do
		if slotsOf(spawns, g) >= 2 then
			dense[#dense + 1] = g
		end
	end
	if #dense > 0 then
		groups = dense
	end
	local clusters, seenVisit = {}, {}
	for gi = 1, math.min(#groups, maxClusters) do
		local g = groups[gi]
		local vx, vy, _, ring = pickVisit(spawns, g, standable, teamFits)
		if vx and not seenVisit[tileKey(vx, vy)] then
			seenVisit[tileKey(vx, vy)] = true
			local copy = {}
			for n, s in ipairs(g) do
				copy[n] = s
			end
			clusters[#clusters + 1] = { spawns = copy, key = tileKey(vx, vy), ring = ring }
		end
	end
	return clusters
end

local function holdKeys(clusters)
	local keys = {}
	for i, c in ipairs(clusters) do
		keys[i] = c.key
	end
	return keys
end

--- Walk distances between every pair of holds, and each hold's BFS parent tree.
local function distanceMatrix(clusters, bfs, xyOf)
	local targets = holdKeys(clusters)
	local trees, d = {}, {}
	for i, c in ipairs(clusters) do
		local x, y = xyOf(c.key)
		local dist, parent = bfs(x, y, nil, targets)
		trees[i] = parent
		d[i] = {}
		for j, other in ipairs(clusters) do
			d[i][j] = dist[other.key] or UNREACHABLE
		end
	end
	return trees, d
end

--- Step 3: merge holds closer than HOLD_MIN_GAP; the matrix shrinks to the kept ones.
local function mergeCloseHolds(spawns, clusters, trees, d)
	local keptIds = spaceHolds(spawns, clusters, d, CaveRoute.HOLD_MIN_GAP)
	local kClusters, kTrees, kd = {}, {}, {}
	for a, i in ipairs(keptIds) do
		kClusters[a] = clusters[i]
		kTrees[a] = trees[i]
		kd[a] = {}
		for b, j in ipairs(keptIds) do
			kd[a][b] = d[i][j]
		end
	end
	return kClusters, kTrees, kd
end

--- The hold the tour starts from: the one nearest the entry when it reaches any,
--- else the densest (1). Also returns the entry key and its BFS (for entryRoute).
local function entryStart(entry, z, clusters, standable, bfs)
	if not entry or floor(tonumber(entry.z) or -1) ~= z then
		return 1
	end
	local ex, ey = floor(entry.x), floor(entry.y)
	local entryKey = tileKey(ex, ey)
	if not standable(ex, ey) then
		return 1, entryKey
	end
	local entryDist, entryParent = bfs(ex, ey, nil, holdKeys(clusters))
	local best
	for i, c in ipairs(clusters) do
		local di = entryDist[c.key]
		if di and (not best or di < entryDist[clusters[best].key]) then
			best = i
		end
	end
	return best or 1, entryKey, entryDist, entryParent
end

--- Steps 4-5: closed tour over the holds reachable from `start`, pruned to the lap cap.
local function planTour(spawns, clusters, d, start, lapMax)
	local reachable = {}
	for j = 1, #clusters do
		if d[start][j] < UNREACHABLE then
			reachable[#reachable + 1] = j
		end
	end
	local weights = {}
	for i, c in ipairs(clusters) do
		weights[i] = slotsOf(spawns, c.spawns)
	end
	return pruneForLap(start, reachable, weights, d, lapMax)
end

--- The tour expanded into its closed walk: tile keys, plus walk index -> cluster index
--- for every hold on it.
local function expandTour(tour, clusters, trees)
	local pathKeys = { clusters[tour[1]].key }
	local holdAt = { [1] = tour[1] }
	if #tour > 1 then
		for i, a in ipairs(tour) do
			local b = tour[i % #tour + 1]
			local leg = pathTo(trees[a], clusters[a].key, clusters[b].key)
			for n = 2, #leg do
				pathKeys[#pathKeys + 1] = leg[n]
			end
			if i < #tour then
				holdAt[#pathKeys] = b
			end
		end
		pathKeys[#pathKeys] = nil -- the closing step lands back on pathKeys[1]
	end
	return pathKeys, holdAt
end

--- Step 6: walk indices kept as waypoints (sorted): holds, dead-end turn tiles and
--- one every WAYPOINT_GAP steps.
local function waypointIndices(pathKeys, holdAt)
	local n = #pathKeys
	local keep = {}
	for i in pairs(holdAt) do
		keep[i] = true
	end
	if n >= 3 then
		for i = 1, n do
			if pathKeys[(i - 2) % n + 1] == pathKeys[i % n + 1] then
				keep[i] = true
			end
		end
	end
	for i = 1, n, CaveRoute.WAYPOINT_GAP do
		keep[i] = true
	end
	local idx = {}
	for i in pairs(keep) do
		idx[#idx + 1] = i
	end
	table.sort(idx)
	return idx
end

--- Closed walk over env.spawns (floor env.z); nil when nothing is walkable. Returns
--- { path, waypoints (hold = true on holds), holds ({ x, y, z, ring }: ring = the
--- hold's standable neighbours), lure, lapSteps, tourSpawns (indices into env.spawns,
--- cluster order), entryRoute (entry → path[1], empty when none) }.
function CaveRoute.build(env)
	local spawns, z = env.spawns, env.z
	local standable, xyOf = probeCache(env.standable)
	local bfs = env.bfs or CaveRoute.makeBfs(standable)

	local clusters = pickClusters(spawns, standable, bfs, env.teamFits, env.maxClusters or CaveRoute.MAX_CLUSTERS)
	if #clusters == 0 then
		return nil
	end
	local trees, d = distanceMatrix(clusters, bfs, xyOf)
	clusters, trees, d = mergeCloseHolds(spawns, clusters, trees, d)
	local start, entryKey, entryDist, entryParent = entryStart(env.entry, z, clusters, standable, bfs)
	local tour = planTour(spawns, clusters, d, start, env.lapMax or CaveRoute.LAP_MAX_STEPS)
	local pathKeys, holdAt = expandTour(tour, clusters, trees)

	local path, pathXY = {}, {}
	for i, k in ipairs(pathKeys) do
		local x, y = xyOf(k)
		path[i] = { x = x, y = y, z = z }
		pathXY[i] = { x, y }
	end
	local waypoints = {}
	for _, i in ipairs(waypointIndices(pathKeys, holdAt)) do
		local p = path[i]
		waypoints[#waypoints + 1] = { x = p.x, y = p.y, z = z, hold = holdAt[i] and true or nil }
	end

	local tourSpawns = {}
	for _, ci in ipairs(tour) do
		for _, s in ipairs(clusters[ci].spawns) do
			tourSpawns[#tourSpawns + 1] = s
		end
	end
	local holdIdx = {}
	for i in pairs(holdAt) do
		holdIdx[#holdIdx + 1] = i
	end
	table.sort(holdIdx)
	local holds = {}
	for h, i in ipairs(holdIdx) do
		holds[h] = { x = path[i].x, y = path[i].y, z = z, ring = clusters[holdAt[i]].ring }
	end

	local entryRoute = {}
	if entryDist and entryDist[pathKeys[1]] then
		for i, k in ipairs(pathTo(entryParent, entryKey, pathKeys[1])) do
			local x, y = xyOf(k)
			entryRoute[i] = { x = x, y = y, z = z }
		end
	end

	local n = #pathKeys
	return {
		path = path,
		waypoints = waypoints,
		holds = holds,
		lure = CaveRoute.lureAlongWalk(pathXY, spawns),
		lapSteps = n > 1 and n or 0,
		tourSpawns = tourSpawns,
		entryRoute = entryRoute,
	}
end
