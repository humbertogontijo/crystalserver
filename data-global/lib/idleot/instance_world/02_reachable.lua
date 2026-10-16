-- Static "can a player ever stand here" lookup for content checks (e.g. discovery
-- viewpoints): true when some instance a player can enter contains pos - a city or
-- city/house (XY mask, every floor), the adventurers' hub, or a catalog hunt (mask + its
-- declared floors). Mirrors InstanceFenceRegistry::canWalk; lobby rooms and raid arenas
-- are not counted. The open world (instance 0) is never walkable.

local CELL = 64

local index = nil

local cellKey = CombatGeo.tileKey

local function addFence(x1, y1, x2, y2, floorSet, occ)
	local fence = { x1 = x1, y1 = y1, x2 = x2, y2 = y2, floorSet = floorSet, occ = occ }
	for cx = math.floor(x1 / CELL), math.floor(x2 / CELL) do
		for cy = math.floor(y1 / CELL), math.floor(y2 / CELL) do
			local key = cellKey(cx, cy)
			local bucket = index[key]
			if not bucket then
				bucket = {}
				index[key] = bucket
			end
			bucket[#bucket + 1] = fence
		end
	end
end

-- Occupancy masks carry their own AABB; without one the fence is the boundary box.
local function addMaskFence(occ, boundary, floorSet)
	if occ and occ.originX and occ.width and occ.height then
		addFence(occ.originX, occ.originY, occ.originX + occ.width - 1, occ.originY + occ.height - 1, floorSet, occ)
		return
	end
	if type(boundary) ~= "table" then
		return
	end
	local x, y, w, h = tonumber(boundary.x), tonumber(boundary.y), tonumber(boundary.w), tonumber(boundary.h)
	if x and y and w and h and w > 0 and h > 0 then
		addFence(x, y, x + w - 1, y + h - 1, floorSet, nil)
	end
end

local function buildIndex()
	index = {}
	for _, city in ipairs(InstanceWorld.cities or {}) do
		addMaskFence(InstanceWorld.occupancyByCityId[city.cityId], city.boundary, nil)
	end
	for _, house in ipairs(InstanceWorld.houses or {}) do
		local hid = house.id
		addMaskFence(hid and InstanceWorld.occupancyByHouseId[hid], house.boundary, nil)
	end

	local hub = InstanceWorld.hubs[1]
	if hub and hub.center then
		local r = InstanceWorld.HUB_WALK_RADIUS
		addFence(hub.center.x - r, hub.center.y - r, hub.center.x + r, hub.center.y + r, select(2, ExpeditionInstance.floorsFromSpec(hub, hub.center.z)), nil)
	end

	-- Hunt footprints come from InstanceWorld.isHuntTile; only boundary-less hunts
	-- (center-only bosses) need a box around the center here.
	for _, hunt in ipairs(ExpeditionConfig.Catalog) do
		local center = hunt.center
		if center and center.x and not hunt.boundary and not InstanceWorld.occupancyByHuntId[hunt.id] then
			local _, floorSet = ExpeditionInstance.floorsFromSpec(hunt, center.z)
			addFence(center.x - 8, center.y - 8, center.x + 8, center.y + 8, floorSet, nil)
		end
	end
end

function InstanceWorld.isReachable(pos)
	if not pos then
		return false
	end
	if InstanceWorld.isHuntTile(pos) then
		return true
	end
	if not index then
		buildIndex()
	end
	local bucket = index[cellKey(math.floor(pos.x / CELL), math.floor(pos.y / CELL))]
	if not bucket then
		return false
	end
	local x, y, z = pos.x, pos.y, pos.z
	for _, fence in ipairs(bucket) do
		if x >= fence.x1 and x <= fence.x2 and y >= fence.y1 and y <= fence.y2 and (not fence.floorSet or fence.floorSet[z]) and (not fence.occ or fence.occ:contains(x, y)) then
			return true
		end
	end
	return false
end
