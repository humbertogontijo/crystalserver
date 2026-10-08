-- Position -> catalog hunt lookup. A hunt's footprint is its XY occupancy mask (or its
-- boundary box when no mask loaded) on its declared floors only, so a city surface tile
-- above an underground hunt (Thais over Thais Underground) is not a hunt tile.
-- Hunts without a boundary have no footprint. Built on first use: the catalog and
-- ExpeditionInstance load after instance_world.

local CELL = 64

local index = nil -- [z][cellKey] = { entry, ... } in catalog order
local indexedCatalog = nil

local cellKey = CombatGeo.tileKey

local function footprint(hunt)
	local occ = hunt.id and InstanceWorld.occupancyByHuntId[hunt.id] or nil
	if occ and occ.originX and occ.width and occ.height then
		return occ.originX, occ.originY, occ.originX + occ.width - 1, occ.originY + occ.height - 1, occ
	end
	local b = hunt.boundary
	if type(b) ~= "table" then
		return nil
	end
	local x, y, w, h = tonumber(b.x), tonumber(b.y), tonumber(b.w), tonumber(b.h)
	if not (x and y and w and h) or w <= 0 or h <= 0 then
		return nil
	end
	return x, y, x + w - 1, y + h - 1, occ
end

local function huntFloors(hunt)
	local floors = ExpeditionInstance and ExpeditionInstance.floorsFromSpec and ExpeditionInstance.floorsFromSpec(hunt) or nil
	if type(floors) == "table" and #floors > 0 then
		return floors
	end
	floors = {}
	for z = 0, 15 do
		floors[#floors + 1] = z
	end
	return floors
end

local function build()
	index = {}
	indexedCatalog = ExpeditionConfig and ExpeditionConfig.Catalog or nil
	for order, hunt in ipairs(indexedCatalog or {}) do
		local x1, y1, x2, y2, occ = footprint(hunt)
		if x1 then
			local entry = { hunt = hunt, order = order, x1 = x1, y1 = y1, x2 = x2, y2 = y2, occ = occ }
			for _, z in ipairs(huntFloors(hunt)) do
				local layer = index[z]
				if not layer then
					layer = {}
					index[z] = layer
				end
				for cx = math.floor(x1 / CELL), math.floor(x2 / CELL) do
					for cy = math.floor(y1 / CELL), math.floor(y2 / CELL) do
						local key = cellKey(cx, cy)
						local bucket = layer[key]
						if not bucket then
							bucket = {}
							layer[key] = bucket
						end
						bucket[#bucket + 1] = entry
					end
				end
			end
		end
	end
end

local function ensureIndex()
	if not index or indexedCatalog ~= (ExpeditionConfig and ExpeditionConfig.Catalog or nil) then
		build()
	end
end

local function contains(entry, x, y)
	if x < entry.x1 or x > entry.x2 or y < entry.y1 or y > entry.y2 then
		return false
	end
	if entry.occ then
		return entry.occ:contains(x, y) and true or false
	end
	return true
end

-- Calls fn(entry) for each footprint covering pos (catalog order per floor) until fn returns true.
-- No z checks every floor.
local function eachAt(pos, fn)
	if not pos or not pos.x or not pos.y then
		return
	end
	ensureIndex()
	local x, y = pos.x, pos.y
	local key = cellKey(math.floor(x / CELL), math.floor(y / CELL))
	local z = pos.z and math.floor(tonumber(pos.z) or -1) or nil
	for fz = z or 0, z or 15 do
		local bucket = index[fz] and index[fz][key]
		if bucket then
			for _, entry in ipairs(bucket) do
				if contains(entry, x, y) and fn(entry) then
					return
				end
			end
		end
	end
end

--- First catalog hunt whose footprint covers pos (catalog order), or nil.
function InstanceWorld.huntAt(pos)
	local best = nil
	eachAt(pos, function(entry)
		if not best or entry.order < best.order then
			best = entry
		end
		return pos.z ~= nil
	end)
	return best and best.hunt or nil
end

--- Every catalog hunt whose footprint covers pos.
function InstanceWorld.huntsAt(pos)
	local list, seen = {}, {}
	eachAt(pos, function(entry)
		if not seen[entry] then
			seen[entry] = true
			list[#list + 1] = entry.hunt
		end
	end)
	return list
end

function InstanceWorld.isHuntTile(pos)
	local found = false
	eachAt(pos, function()
		found = true
		return true
	end)
	return found
end
