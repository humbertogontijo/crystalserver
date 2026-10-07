-- Discovery subarea footprints + floor rules, built from DiscoveryGeometry (geometry.lua).
-- Pure Lua (no engine API): packages/asset-pipeline/src/features/discovery/gen_pois.py runs
-- this file through lupa so tibiamaps viewpoints are assigned with the exact rules the
-- server uses to decide which subarea session a player is in.
--
-- floors = where the player counts as inside (detection, incl. rooftops/mountain tops).
-- Surface subareas come from the client masks (207 pixel-exact, mutually disjoint
-- footprints); underground ones from DiscoveryGeometry.approx or MANUAL_SUBAREAS.
-- Below the surface, a CIP subarea also covers its region from lib/idleot/subareas
-- (DiscoverySubareas.regionCipAt): only cave-like subareas and the ones listed in
-- asset-pipeline subarea_floor_rules.py extend underground (Gloom Caverns, Fibula,
-- Rookgaard, ...); cities stop at z7, so their sewers are left.

DiscoverySubareas = {}

local SURFACE = { 0, 1, 2, 3, 4, 5, 6, 7 }

-- per-subarea tweaks on top of the generated geometry
local OVERRIDES = {
	[33] = { floors = { 8, 9 } }, -- Trolls' Cave: underground, mask = horizontal footprint (surface is not the cave)
}

--- Optional `function(position) -> CIP subarea id | nil` from the region map (set by the
--- server, and by gen_pois.py when it assigns viewpoints).
DiscoverySubareas.regionCipAt = nil

-- hand-made subareas (none right now - undergrounds come from DiscoveryGeometry.approx);
-- format: { id, mainArea, name, floors, boxes = { { from = {x,y}, to = {x,y}, floors? } } }
local MANUAL_SUBAREAS = {}

local function floorSetOf(list)
	local set = {}
	for _, z in ipairs(list) do
		set[z] = true
	end
	return set
end

-- "x1,y1,x2,y2 x1,y1,x2,y2 ..." -> flat number array (stride 4)
local function parseRects(str)
	local flat = {}
	local n = 0
	for x1, y1, x2, y2 in str:gmatch("(%d+),(%d+),(%d+),(%d+)") do
		flat[n + 1] = tonumber(x1)
		flat[n + 2] = tonumber(y1)
		flat[n + 3] = tonumber(x2)
		flat[n + 4] = tonumber(y2)
		n = n + 4
	end
	return flat
end

-- def carries: rects = flat array (uniform def.floors) + extra = { {x1,y1,x2,y2, floors} }
-- (per-box floor exceptions). finalizeDef computes bbox and floor sets.
local function finalizeDef(def)
	local bb = def.bbox and { x1 = def.bbox.x1, y1 = def.bbox.y1, x2 = def.bbox.x2, y2 = def.bbox.y2 } or nil
	local rects = def.rects
	for i = 1, #rects, 4 do
		local x1, y1, x2, y2 = rects[i], rects[i + 1], rects[i + 2], rects[i + 3]
		if not bb then
			bb = { x1 = x1, y1 = y1, x2 = x2, y2 = y2 }
		else
			bb.x1 = math.min(bb.x1, x1)
			bb.y1 = math.min(bb.y1, y1)
			bb.x2 = math.max(bb.x2, x2)
			bb.y2 = math.max(bb.y2, y2)
		end
	end
	def.extra = def.extra or {}
	for _, e in ipairs(def.extra) do
		bb.x1 = math.min(bb.x1, e.x1)
		bb.y1 = math.min(bb.y1, e.y1)
		bb.x2 = math.max(bb.x2, e.x2)
		bb.y2 = math.max(bb.y2, e.y2)
		e.floorSet = floorSetOf(e.floors)
	end
	def.bbox = bb
	def.floorSet = floorSetOf(def.floors)
	return def
end

local list = {}
local byId = {}

local function addDef(def)
	finalizeDef(def)
	list[#list + 1] = def
	byId[def.id] = def
end

local function sortedKeys(tbl)
	local keys = {}
	for k in pairs(tbl) do
		keys[#keys + 1] = k
	end
	table.sort(keys)
	return keys
end

for _, def in ipairs(MANUAL_SUBAREAS) do
	local flat = {}
	local extras = {}
	for _, box in ipairs(def.boxes) do
		if box.floors then
			extras[#extras + 1] = { x1 = box.from.x, y1 = box.from.y, x2 = box.to.x, y2 = box.to.y, floors = box.floors }
		else
			flat[#flat + 1] = box.from.x
			flat[#flat + 1] = box.from.y
			flat[#flat + 1] = box.to.x
			flat[#flat + 1] = box.to.y
		end
	end
	def.rects = flat
	def.extra = extras
	def.boxes = nil
	addDef(def)
end

-- pixel-exact surface footprints (client masks)
for _, sid in ipairs(sortedKeys(DiscoveryGeometry.subs)) do
	local g = DiscoveryGeometry.subs[sid]
	local ov = OVERRIDES[sid] or {}
	local extras = {}
	for _, box in ipairs(ov.extraBoxes or {}) do
		extras[#extras + 1] = { x1 = box.from.x, y1 = box.from.y, x2 = box.to.x, y2 = box.to.y, floors = box.floors or { 7 } }
	end
	addDef({
		id = sid,
		mainArea = g.mainArea,
		name = g.name,
		floors = ov.floors or SURFACE,
		rects = parseRects(g.rects),
		extra = extras,
		bbox = g.bbox,
	})
end

-- approximate underground boxes (landmark clusters) - AFTER the exact ones, so an exact
-- footprint always wins the first-match scan
for _, sid in ipairs(sortedKeys(DiscoveryGeometry.approx or {})) do
	local g = DiscoveryGeometry.approx[sid]
	local ov = OVERRIDES[sid] or {}
	addDef({
		id = sid,
		mainArea = g.mainArea,
		name = g.name,
		approx = true,
		floors = ov.floors or g.floors,
		rects = { g.box.x1, g.box.y1, g.box.x2, g.box.y2 },
	})
end

DiscoverySubareas.list = list
DiscoverySubareas.byId = byId

function DiscoverySubareas.contains(position, def)
	local bb = def.bbox
	local x, y, z = position.x, position.y, position.z
	if x < bb.x1 or x > bb.x2 or y < bb.y1 or y > bb.y2 then
		return false
	end
	if def.floorSet[z] then
		local r = def.rects
		for i = 1, #r, 4 do
			if x >= r[i] and x <= r[i + 2] and y >= r[i + 1] and y <= r[i + 3] then
				return true
			end
		end
	end
	for _, e in ipairs(def.extra) do
		if e.floorSet[z] and x >= e.x1 and x <= e.x2 and y >= e.y1 and y <= e.y2 then
			return true
		end
	end
	return false
end

local function regionDef(position)
	local cipId = DiscoverySubareas.regionCipAt and DiscoverySubareas.regionCipAt(position)
	return cipId and byId[cipId] or nil
end

--- Footprint or region membership of `position` in `def`.
function DiscoverySubareas.inSubarea(position, def)
	return DiscoverySubareas.contains(position, def) or regionDef(position) == def
end

--- First matching subarea (manual, then exact surface masks, then approx boxes), then the
--- CIP subarea whose region holds `position`.
function DiscoverySubareas.find(position)
	for _, def in ipairs(list) do
		if DiscoverySubareas.contains(position, def) then
			return def.id, def
		end
	end
	local def = regionDef(position)
	if def then
		return def.id, def
	end
	return nil, nil
end
