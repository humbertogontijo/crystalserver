-- Shared tile / distance helpers for combat automation and expeditions.

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

--- Wall-clock ms (OTSYS_TIME). os.clock() is CPU time and os.time() has 1 s resolution.
function CombatGeo.nowMs()
	if type(systemTime) == "function" then
		return math.floor(systemTime())
	end
	return math.floor(os.time() * 1000)
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
	if not tile or not tile:getGround() then
		return nil
	end
	local function blocks(prop)
		if instanceId then
			return tile:hasProperty(prop, instanceId)
		end
		return tile:hasProperty(prop)
	end
	if blocks(CONST_PROP_BLOCKSOLID) or blocks(CONST_PROP_IMMOVABLEBLOCKSOLID) or blocks(CONST_PROP_BLOCKPATH) then
		return nil
	end
	if tile:hasFlag(TILESTATE_FLOORCHANGE) or tile:hasFlag(TILESTATE_PROTECTIONZONE) then
		return nil
	end
	return tile
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

--- Stepping `from` -> `dest` moves farther from the player's path leash anchor while
--- `from` is already outside the leash radius.
function CombatGeo.fartherFromLeash(player, from, dest)
	if not player.getPathLeashRadius or not player.getPathLeashAnchor then
		return false
	end
	local radius = player:getPathLeashRadius()
	if type(radius) ~= "number" or radius <= 0 then
		return false
	end
	local anchor = player:getPathLeashAnchor()
	if not anchor or anchor.z ~= dest.z then
		return false
	end
	local now = CombatGeo.chebyshev(from, anchor)
	return now > radius and CombatGeo.chebyshev(dest, anchor) > now
end
