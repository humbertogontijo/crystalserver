-- CaveBot-style hunt route: one closed walk over a hunt's spawn clusters. Single
-- implementation shared by the runtime (open-world routes, cavebot/08_routes.lua) and
-- hunt generation, which loads this file and 00_anchor_spot.lua through lupa
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
--         WalkGrid:bfs); keyed by AnchorSpot.tileKey, same neighbour order
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
local NEIGHBOURS = { { 0, -1 }, { 1, 0 }, { 0, 1 }, { -1, 0 }, { 1, -1 }, { 1, 1 }, { -1, 1 }, { -1, -1 } }

local floor = math.floor

local function tileKey(x, y)
	return x * 65536 + y
end

local function keyXY(key)
	local x = floor(key / 65536)
	return x, key - x * 65536
end

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

--- Closed walk over env.spawns (floor env.z); nil when nothing is walkable. Returns
--- { path, waypoints (hold = true on holds), holds, lure, lapSteps, tourSpawns (indices
--- into env.spawns, cluster order), entryRoute (entry → path[1], empty when none) }.
function CaveRoute.build(env)
	local spawns, z = env.spawns, env.z
	local rawStandable = env.standable
	-- Coordinates of every probed tile: keys only decode for 0 <= y < 65536.
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
	local bfs = env.bfs or CaveRoute.makeBfs(standable)
	local lapMax = env.lapMax or CaveRoute.LAP_MAX_STEPS
	local maxClusters = env.maxClusters or CaveRoute.MAX_CLUSTERS

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
		local vx, vy = pickVisit(spawns, g, standable, env.teamFits)
		if vx and not seenVisit[tileKey(vx, vy)] then
			seenVisit[tileKey(vx, vy)] = true
			local copy = {}
			for n, s in ipairs(g) do
				copy[n] = s
			end
			clusters[#clusters + 1] = { spawns = copy, key = tileKey(vx, vy) }
		end
	end
	if #clusters == 0 then
		return nil
	end

	local targets = {}
	for i, c in ipairs(clusters) do
		targets[i] = c.key
	end
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
	clusters, trees, d = kClusters, kTrees, kd
	targets = {}
	for i, c in ipairs(clusters) do
		targets[i] = c.key
	end

	local entry = env.entry
	local entryKey, entryDist, entryParent = nil, nil, nil
	if entry and floor(tonumber(entry.z) or -1) == z then
		entryKey = tileKey(floor(entry.x), floor(entry.y))
	end
	local start = 1 -- densest cluster
	if entryKey and standable(floor(entry.x), floor(entry.y)) then
		entryDist, entryParent = bfs(floor(entry.x), floor(entry.y), nil, targets)
		local any = false
		for _, c in ipairs(clusters) do
			if entryDist[c.key] then
				any = true
				break
			end
		end
		if any then
			local best
			for i, c in ipairs(clusters) do
				local di = entryDist[c.key] or UNREACHABLE
				if not best or di < (entryDist[clusters[best].key] or UNREACHABLE) then
					best = i
				end
			end
			start = best
		end
	end
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
	local tour = pruneForLap(start, reachable, weights, d, lapMax)

	local pathKeys = { clusters[tour[1]].key }
	local visitIdx = { [1] = true }
	if #tour > 1 then
		for i, a in ipairs(tour) do
			local b = tour[i % #tour + 1]
			local leg = pathTo(trees[a], clusters[a].key, clusters[b].key)
			for n = 2, #leg do
				pathKeys[#pathKeys + 1] = leg[n]
			end
			if i < #tour then
				visitIdx[#pathKeys] = true
			end
		end
		pathKeys[#pathKeys] = nil -- the closing step lands back on pathKeys[1]
	end

	local n = #pathKeys
	local keep = {}
	for i in pairs(visitIdx) do
		keep[i] = true
	end
	if n >= 3 then
		for i = 1, n do
			local prev = pathKeys[(i - 2) % n + 1]
			local nxt = pathKeys[i % n + 1]
			if prev == nxt then
				keep[i] = true
			end
		end
	end
	for i = 1, n, CaveRoute.WAYPOINT_GAP do
		keep[i] = true
	end
	local wpIdx = {}
	for i in pairs(keep) do
		wpIdx[#wpIdx + 1] = i
	end
	table.sort(wpIdx)

	local path, pathXY = {}, {}
	for i, k in ipairs(pathKeys) do
		local x, y = xyOf(k)
		path[i] = { x = x, y = y, z = z }
		pathXY[i] = { x, y }
	end
	local waypoints = {}
	for _, i in ipairs(wpIdx) do
		local p = path[i]
		waypoints[#waypoints + 1] = { x = p.x, y = p.y, z = z, hold = visitIdx[i] or nil }
	end

	local tourSpawns = {}
	for _, ci in ipairs(tour) do
		for _, s in ipairs(clusters[ci].spawns) do
			tourSpawns[#tourSpawns + 1] = s
		end
	end
	local holdIdx = {}
	for i in pairs(visitIdx) do
		holdIdx[#holdIdx + 1] = i
	end
	table.sort(holdIdx)
	local holds = {}
	for h, i in ipairs(holdIdx) do
		holds[h] = { x = path[i].x, y = path[i].y, z = z }
	end

	local entryRoute = {}
	if entryKey and entryDist and entryDist[pathKeys[1]] then
		for i, k in ipairs(pathTo(entryParent, entryKey, pathKeys[1])) do
			local x, y = xyOf(k)
			entryRoute[i] = { x = x, y = y, z = z }
		end
	end

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
