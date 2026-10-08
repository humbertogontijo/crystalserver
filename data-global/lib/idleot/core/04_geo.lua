-- Shared tile / distance helpers for every product module. The pure part (keys,
-- offsets, bounds, occupancy, Progress) also runs in the asset pipeline (lupa).

CombatGeo = CombatGeo or {}

-- Client viewport half-extents used for "on screen" checks (one extra tile of
-- margin over the stock 7x5 so edge monsters count).
CombatGeo.VIEWPORT_X = 8
CombatGeo.VIEWPORT_Y = 6

CombatGeo.CARDINAL_OFFSETS = { { 0, -1 }, { 1, 0 }, { 0, 1 }, { -1, 0 } }

CombatGeo.NEIGHBOUR_OFFSETS = {
	{ 0, -1 },
	{ 1, 0 },
	{ 0, 1 },
	{ -1, 0 },
	{ 1, -1 },
	{ 1, 1 },
	{ -1, 1 },
	{ -1, -1 },
}

--- Integer key of a tile on one floor (x, y < 65536); `keyXY` inverts it.
function CombatGeo.tileKey(x, y)
	return x * 65536 + y
end

function CombatGeo.keyXY(key)
	local x = math.floor(key / 65536)
	return x, key - x * 65536
end

--- "x,y,z" key of a position (nil for nil).
function CombatGeo.posKey(pos)
	return pos and string.format("%d,%d,%d", pos.x, pos.y, pos.z) or nil
end

--- Engine Position of a plain {x, y, z} table (nil for nil).
function CombatGeo.toPosition(p)
	return p and Position(p.x, p.y, p.z) or nil
end

--- Bounding box x1, y1, x2, y2 of a list of {x, y} points (nil when empty).
function CombatGeo.bounds(points)
	local x1, y1, x2, y2 = math.huge, math.huge, -math.huge, -math.huge
	for _, p in ipairs(points) do
		x1, y1 = math.min(x1, p.x), math.min(y1, p.y)
		x2, y2 = math.max(x2, p.x), math.max(y2, p.y)
	end
	if x1 > x2 then
		return nil
	end
	return x1, y1, x2, y2
end

--- Raw occupancy bit mask { originX, originY, width, height, bits } (LSB first,
--- row-major; the Game.setInstancePrivateFence layout).
function CombatGeo.maskContains(mask, x, y)
	local lx, ly = x - mask.originX, y - mask.originY
	if lx < 0 or ly < 0 or lx >= mask.width or ly >= mask.height then
		return false
	end
	local i = ly * mask.width + lx
	local byte = mask.bits:byte(math.floor(i / 8) + 1) or 0
	return math.floor(byte / 2 ^ (i % 8)) % 2 == 1
end

--- Occupancy test of an engine mask (`occ:contains`) or a raw bit mask.
function CombatGeo.occupancyContains(occ, x, y)
	if occ.contains then
		return occ:contains(x, y) and true or false
	end
	return CombatGeo.maskContains(occ, x, y)
end

--- Stall timer for a value that should keep shrinking (a distance, a lag): a plain
--- { best, at } table, so it can live in any state table.
CombatGeo.Progress = {}

function CombatGeo.Progress.new(now)
	return { best = math.huge, at = now }
end

--- True when `value` is a new best (the stall clock restarts).
function CombatGeo.Progress.improve(progress, value, now)
	if value < progress.best then
		progress.best, progress.at = value, now
		return true
	end
	return false
end

--- No new best for more than `ms`.
function CombatGeo.Progress.stalled(progress, now, ms)
	return now - progress.at > ms
end

--- Wall-clock ms (OTSYS_TIME). os.clock() is CPU time and os.time() has 1 s resolution.
function CombatGeo.nowMs()
	return math.floor(systemTime())
end

--- Chebyshev distance; math.huge when either is missing or they are on different floors.
function CombatGeo.chebyshev(a, b)
	if not a or not b or a.z ~= b.z then
		return math.huge
	end
	return math.max(math.abs(a.x - b.x), math.abs(a.y - b.y))
end

function CombatGeo.sameTile(a, b)
	return a ~= nil and b ~= nil and a.x == b.x and a.y == b.y and a.z == b.z
end

function CombatGeo.signOf(n)
	return n > 0 and 1 or (n < 0 and -1 or 0)
end

--- On a straight N/E/S/W line from the anchor (not on its tile).
function CombatGeo.onAnchorLane(pos, apos)
	return apos ~= nil and pos.z == apos.z and (pos.x == apos.x) ~= (pos.y == apos.y)
end

function CombatGeo.isInViewport(fromPos, toPos)
	if not fromPos or not toPos or fromPos.z ~= toPos.z then
		return false
	end
	return math.abs(fromPos.x - toPos.x) <= CombatGeo.VIEWPORT_X and math.abs(fromPos.y - toPos.y) <= CombatGeo.VIEWPORT_Y
end

local FACING_OFFSETS = {
	[DIRECTION_NORTH] = { 0, -1 },
	[DIRECTION_EAST] = { 1, 0 },
	[DIRECTION_SOUTH] = { 0, 1 },
	[DIRECTION_WEST] = { -1, 0 },
}

--- `pos` lies in the cone in front of a creature at `cpos` facing `dir` (N/E/S/W):
--- from the tile it faces, one tile wider on each side per tile out, up to `range`.
--- `dir` nil: the creature turns to face `pos` (a monster facing its target), so only
--- exact diagonals stay out. Exact diagonals are never in the cone.
function CombatGeo.inFrontCone(cpos, dir, pos, range)
	if not cpos or not pos or cpos.z ~= pos.z then
		return false
	end
	local dx, dy = pos.x - cpos.x, pos.y - cpos.y
	local forward, lateral
	if dir == nil then
		forward, lateral = math.max(math.abs(dx), math.abs(dy)), math.min(math.abs(dx), math.abs(dy))
	else
		local f = FACING_OFFSETS[dir]
		if not f then
			return false
		end
		if f[1] ~= 0 then
			forward, lateral = dx * f[1], math.abs(dy)
		else
			forward, lateral = dy * f[2], math.abs(dx)
		end
	end
	return forward >= 1 and forward <= range and lateral <= forward - 1
end

--- Offset (dx, dy) given for a creature facing north, turned to face `dir` (N/E/S/W).
function CombatGeo.rotateOffset(dx, dy, dir)
	if dir == DIRECTION_EAST then
		return -dy, dx
	elseif dir == DIRECTION_SOUTH then
		return -dx, -dy
	elseif dir == DIRECTION_WEST then
		return dy, -dx
	end
	return dx, dy
end

--- Turn `player` toward `toPos` (dominant axis; same floor only).
function CombatGeo.faceToward(player, toPos)
	if not player or not toPos then
		return
	end
	local fromPos = player:getPosition()
	if not fromPos or fromPos.z ~= toPos.z then
		return
	end
	local dx = toPos.x - fromPos.x
	local dy = toPos.y - fromPos.y
	if dx == 0 and dy == 0 then
		return
	end
	local dir
	if math.abs(dx) > math.abs(dy) then
		dir = dx > 0 and DIRECTION_EAST or DIRECTION_WEST
	else
		dir = dy > 0 and DIRECTION_SOUTH or DIRECTION_NORTH
	end
	if player:getDirection() ~= dir then
		player:setDirection(dir)
	end
end

--- Ground a player may stand on to fight (no walls, blocking items, stairs or PZ).
--- `instanceId` limits blocking items to that instance.
function CombatGeo.tileStandable(pos, instanceId)
	local tile = pos and Tile(pos)
	if tile and tile:isStandable(instanceId) then
		return tile
	end
	return nil
end

--- Standable and empty (or holding only `self`). With `instanceId`, only creatures
--- in that instance occupy the tile.
function CombatGeo.tileFree(pos, self, instanceId)
	local tile = CombatGeo.tileStandable(pos, instanceId)
	if not tile then
		return false
	end
	local selfId = self and self:getId()
	if instanceId then
		for _, other in ipairs(tile:getCreatures() or {}) do
			if other:getInstanceId() == instanceId and other:getId() ~= selfId then
				return false
			end
		end
		return true
	end
	local top = tile:getTopCreature()
	return not top or top:getId() == selfId
end

--- Empty standable tiles among the 8 neighbours of `pos`.
function CombatGeo.freeNeighbourCount(pos, self, instanceId)
	if not pos then
		return 0
	end
	local n = 0
	for _, off in ipairs(CombatGeo.NEIGHBOUR_OFFSETS) do
		if CombatGeo.tileFree(Position(pos.x + off[1], pos.y + off[2], pos.z), self, instanceId) then
			n = n + 1
		end
	end
	return n
end

--- Stepping `from` -> `dest` ends outside the player's path leash radius and farther
--- from its anchor than `from` (the engine path search's leash rule).
function CombatGeo.fartherFromLeash(player, from, dest)
	local radius = player:getPathLeashRadius()
	if type(radius) ~= "number" or radius <= 0 then
		return false
	end
	local anchor = player:getPathLeashAnchor()
	if not anchor or anchor.z ~= dest.z then
		return false
	end
	local later = CombatGeo.chebyshev(dest, anchor)
	return later > radius and later > CombatGeo.chebyshev(from, anchor)
end
