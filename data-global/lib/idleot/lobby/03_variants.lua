-- Lobby room variants: identical stamped rooms (walls, floor, fixtures) laid out in a grid,
-- differing only in the CENTER_SIZE center. The default variant keeps plain floor; each lever
-- boss gets a variant whose center is a clone of its real lever room (ground, fixed decor,
-- slots, lever) framed by CENTER_BORDER overlays. Grounds cannot differ per instance, so a
-- lobby switches rooms by moving its private fence (LobbyInstance.applyVariant).
LobbyVariants = LobbyVariants or {}

local variants = {} -- key -> variant
local ordered = {} -- grid index + 1 -> variant

local function outerW()
	return LobbyConfig.ROOM_FLOOR_W + 2
end

local function outerH()
	return LobbyConfig.ROOM_FLOOR_H + 2
end

function LobbyVariants.outerSize()
	return outerW(), outerH()
end

local function gridOrigin(index)
	local cols = LobbyConfig.VARIANT_COLUMNS
	local stride = LobbyConfig.VARIANT_STRIDE
	return Position(
		LobbyConfig.ROOM_BASE_X + (index % cols) * stride,
		LobbyConfig.ROOM_BASE_Y + math.floor(index / cols) * stride,
		LobbyConfig.ROOM_Z
	)
end

local function wallId(lx, ly)
	local maxX, maxY = outerW() - 1, outerH() - 1
	local onN, onS = ly == 0, ly == maxY
	local onW, onE = lx == 0, lx == maxX
	if onN and onW then
		return LobbyConfig.ROOM_WALL_TL
	elseif onN and onE then
		return LobbyConfig.ROOM_WALL_TR
	elseif onS and onW then
		return LobbyConfig.ROOM_WALL_BL
	elseif onS and onE then
		return LobbyConfig.ROOM_WALL_BR
	elseif onN or onS then
		return LobbyConfig.ROOM_WALL_H
	elseif onW or onE then
		return LobbyConfig.ROOM_WALL_V
	end
	return nil
end

local function ensureTile(pos)
	return Tile(pos) or Game.createTile(pos, false)
end

local function ensureGround(pos, itemId)
	local tile = ensureTile(pos)
	if not tile then
		return nil
	end
	local ground = tile:getGround()
	if not ground then
		Game.createItem(itemId, 1, pos)
	elseif ground:getId() ~= itemId then
		ground:transform(itemId)
	end
	return Tile(pos)
end

local function ensureItem(pos, itemId, actionId)
	local tile = ensureTile(pos)
	if not tile then
		return nil
	end
	local item = tile:getItemById(itemId)
	if not item then
		item = Game.createItem(itemId, 1, pos)
	end
	if item and actionId then
		item:setActionId(actionId)
	end
	return item
end

local function clearItems(pos)
	local tile = Tile(pos)
	if not tile then
		return
	end
	local items = tile:getItems() or {}
	for i = #items, 1, -1 do
		items[i]:remove()
	end
end

local function blocksWalk(itemId)
	local it = ItemType(itemId)
	return it and it:getId() ~= 0 and it:isBlocking() or false
end

--- Map unique id (0 when none): getUniqueId falls back to a script uid above the uint16 range.
local function mapUid(item)
	local uid = item:getUniqueId() or 0
	return uid <= 0xFFFF and uid or 0
end

local function isLeverItem(item, lever)
	if lever._uid and mapUid(item) == lever._uid then
		return true
	end
	return lever._aid ~= nil and item:getActionId() == lever._aid
end

--- Real lever tile near slot 1 (uid / aid match within 2 tiles, or the lever's registered position).
--- A position-registered "lever" can be any usable item (Timira: trapped water 39271, a top-order
--- item), so that tile falls back to its top item.
local function findLever(lever, slot1)
	if lever._position then
		local p = Position(lever._position)
		if p.z == slot1.z and math.abs(p.x - slot1.x) <= 2 and math.abs(p.y - slot1.y) <= 2 then
			local tile = Tile(p)
			local top = tile and (tile:getTopDownItem() or tile:getTopTopItem())
			if top then
				return p, top:getId()
			end
		end
	end
	for dy = -2, 2 do
		for dx = -2, 2 do
			local p = Position(slot1.x + dx, slot1.y + dy, slot1.z)
			local tile = Tile(p)
			for _, item in ipairs(tile and tile:getItems() or {}) do
				if isLeverItem(item, lever) then
					return p, item:getId()
				end
			end
		end
	end
	return nil, nil
end

--- Neighbour of slot 1 for a placed lever: off the slot line first, never on a slot.
local function fallbackLeverPos(slots)
	local s1 = slots[1]
	local taken = {}
	local horizontal = true
	for _, s in ipairs(slots) do
		taken[s.x .. ":" .. s.y] = true
		if s.y ~= s1.y then
			horizontal = false
		end
	end
	local order = horizontal and { { 0, -1 }, { 0, 1 }, { -1, 0 }, { 1, 0 } } or { { -1, 0 }, { 1, 0 }, { 0, -1 }, { 0, 1 } }
	for _, d in ipairs(order) do
		local x, y = s1.x + d[1], s1.y + d[2]
		if not taken[x .. ":" .. y] then
			return Position(x, y, s1.z)
		end
	end
	return nil
end

--- Decor worth copying into the lobby: fixed, inert, and not bound to a script.
local function cloneable(item, isLever)
	if isLever then
		return true
	end
	local it = ItemType(item:getId())
	if not it or it:getId() == 0 then
		return false
	end
	if it:isMovable() or it:isContainer() or it:isMagicField() or it:isDoor() then
		return false
	end
	if it:getType() == ITEM_TYPE_TELEPORT then
		return false
	end
	return mapUid(item) == 0 and (item:getActionId() or 0) == 0
end

local function borderFor(lx, ly)
	local last = LobbyConfig.CENTER_SIZE - 1
	local n, s = ly == 0, ly == last
	local w, e = lx == 0, lx == last
	local b = LobbyConfig.CENTER_BORDER
	if n and w then
		return b.nw
	elseif n and e then
		return b.ne
	elseif s and w then
		return b.sw
	elseif s and e then
		return b.se
	elseif n then
		return b.n
	elseif s then
		return b.s
	elseif w then
		return b.w
	elseif e then
		return b.e
	end
	return nil
end

--- Walls, floor (PZ) and fixtures of one variant room.
local function stampShell(variant)
	local o, fo = variant.origin, variant.floorOrigin
	local floorId = LobbyConfig.ROOM_FLOOR_ID
	for ly = 0, LobbyConfig.ROOM_FLOOR_H - 1 do
		for lx = 0, LobbyConfig.ROOM_FLOOR_W - 1 do
			local tile = ensureGround(Position(fo.x + lx, fo.y + ly, fo.z), floorId)
			if tile and tile.setFlag then
				tile:setFlag(TILESTATE_PROTECTIONZONE)
			end
		end
	end
	local maxX, maxY = outerW() - 1, outerH() - 1
	for ly = 0, maxY do
		for lx = 0, maxX do
			local id = wallId(lx, ly)
			if id then
				local pos = Position(o.x + lx, o.y + ly, o.z)
				-- The NE / SW corner sprites are drawn without floor beneath them.
				if (lx == maxX and ly == 0) or (lx == 0 and ly == maxY) then
					ensureTile(pos)
				else
					ensureGround(pos, floorId)
				end
				ensureItem(pos, id)
			end
		end
	end
	for _, spec in ipairs(LobbyConfig.fixtureLayout()) do
		ensureItem(Position(fo.x + spec.dx, fo.y + spec.dy, fo.z), spec.id, spec.actionId or LobbyConfig.FIXTURE_ACTION_ID)
	end
end

--- Clone the lever room into the variant center. Returns false when the layout does not fit.
local function stampLeverCenter(variant, lever)
	local slots = {}
	for i, entry in ipairs(lever.playerPositions or {}) do
		slots[i] = Position(entry.pos)
	end
	if #slots == 0 then
		return false
	end
	local z = slots[1].z
	local leverPos, leverId = findLever(lever, slots[1])
	local placedLever = leverPos == nil
	if placedLever then
		leverPos = fallbackLeverPos(slots)
		leverId = LobbyConfig.LEVER_FALLBACK_ID
	end
	local minX, minY, maxX, maxY = math.huge, math.huge, -math.huge, -math.huge
	local function grow(p)
		minX, minY = math.min(minX, p.x), math.min(minY, p.y)
		maxX, maxY = math.max(maxX, p.x), math.max(maxY, p.y)
	end
	for _, s in ipairs(slots) do
		grow(s)
	end
	if leverPos then
		grow(leverPos)
	end
	local size = LobbyConfig.CENTER_SIZE
	if maxX - minX + 1 > size or maxY - minY + 1 > size then
		logger.warn("[Lobby] lever room of {} does not fit the {}x{} center", lever.name, size, size)
		return false
	end
	local wx = minX - math.floor((size - (maxX - minX + 1)) / 2)
	local wy = minY - math.floor((size - (maxY - minY + 1)) / 2)

	local fo = variant.floorOrigin
	local cx, cy = fo.x + LobbyConfig.CENTER_OFFSET, fo.y + LobbyConfig.CENTER_OFFSET
	local keep = {}
	for _, s in ipairs(slots) do
		keep[(s.x - wx) .. ":" .. (s.y - wy)] = true
	end
	local leverLx, leverLy = leverPos and leverPos.x - wx, leverPos and leverPos.y - wy

	for ly = 0, size - 1 do
		for lx = 0, size - 1 do
			local src = Tile(Position(wx + lx, wy + ly, z))
			local dst = Position(cx + lx, cy + ly, LobbyConfig.ROOM_Z)
			local onLever = lx == leverLx and ly == leverLy
			local open = keep[lx .. ":" .. ly] or lx == 0 or ly == 0 or lx == size - 1 or ly == size - 1
			local groundId = LobbyConfig.ROOM_FLOOR_ID
			local copies = {}
			local ground = src and src:getGround()
			if ground and not src:hasFlag(TILESTATE_FLOORCHANGE) and not src:hasFlag(TILESTATE_TELEPORT) then
				if not (open and blocksWalk(ground:getId())) then
					groundId = ground:getId()
				end
				local items = src:getItems() or {}
				for i = #items, 1, -1 do
					local item = items[i]
					local isLever = not placedLever and onLever and item:getId() == leverId
					if cloneable(item, isLever) and (isLever or not (open and blocksWalk(item:getId()))) then
						copies[#copies + 1] = item:getId()
					end
				end
			end
			clearItems(dst)
			local tile = ensureGround(dst, groundId)
			if tile and tile.setFlag then
				tile:setFlag(TILESTATE_PROTECTIONZONE)
			end
			for _, id in ipairs(copies) do
				local item = Game.createItem(id, 1, dst)
				if item and onLever and id == leverId then
					item:setActionId(LobbyConfig.LEVER_ACTION_ID)
				end
			end
			if onLever and placedLever then
				ensureItem(dst, leverId, LobbyConfig.LEVER_ACTION_ID)
			end
			local border = borderFor(lx, ly)
			if border then
				Game.createItem(border, 1, dst)
			end
		end
	end

	local base = LobbyConfig.CENTER_OFFSET
	variant.slots = {}
	for i, s in ipairs(slots) do
		variant.slots[i] = { base + s.x - wx, base + s.y - wy }
	end
	variant.lever = leverPos and { base + leverLx, base + leverLy } or nil
	return true
end

local function register(key, index, extra)
	local o = gridOrigin(index)
	local variant = {
		key = key,
		index = index,
		origin = o,
		floorOrigin = Position(o.x + 1, o.y + 1, o.z),
		slots = nil,
		lever = nil,
	}
	for k, v in pairs(extra or {}) do
		variant[k] = v
	end
	variants[key] = variant
	ordered[index + 1] = variant
	return variant
end

local function isLeverEncounter(entry)
	if entry.role ~= "boss" and entry.kind ~= "boss" then
		return false
	end
	return ExpeditionConfig.bossEncounter(entry) == "lever"
end

--- Lever-boss levers referenced by the catalog, sorted by boss name.
local function catalogLevers()
	local seen, list = {}, {}
	for _, entry in ipairs(ExpeditionConfig and ExpeditionConfig.Catalog or {}) do
		if isLeverEncounter(entry) then
			local lever = ExpeditionConfig.bossLever(entry)
			if lever and not seen[lever.name] then
				seen[lever.name] = true
				list[#list + 1] = lever
			end
		end
	end
	table.sort(list, function(a, b)
		return a.name < b.name
	end)
	return list
end

--- Stamp every variant (default first). Safe to call again after a reload.
function LobbyVariants.stampAll()
	variants, ordered = {}, {}
	stampShell(register(LobbyConfig.DEFAULT_VARIANT, 0))
	local index, skipped = 1, 0
	for _, lever in ipairs(catalogLevers()) do
		local variant = register(lever.name, index, { bossName = lever.name })
		stampShell(variant)
		if stampLeverCenter(variant, lever) then
			index = index + 1
		else
			-- Nothing was cloned; the next lever room reuses this grid cell.
			variants[lever.name] = nil
			ordered[index + 1] = nil
			skipped = skipped + 1
		end
	end
	logger.info("[Lobby] stamped {} room variants ({} lever rooms, {} skipped)", #ordered, #ordered - 1, skipped)
	return true
end

function LobbyVariants.get(key)
	return variants[key] or variants[LobbyConfig.DEFAULT_VARIANT]
end

function LobbyVariants.default()
	return variants[LobbyConfig.DEFAULT_VARIANT]
end

--- Variant for the lobby's picked expedition (default unless it is a lever boss with a room).
function LobbyVariants.keyForRecord(record)
	if not record or record.role ~= "boss" or (record.expeditionId or "") == "" then
		return LobbyConfig.DEFAULT_VARIANT
	end
	local catalog = ExpeditionConfig.getById(record.expeditionId, "boss")
	if not catalog or not isLeverEncounter(catalog) then
		return LobbyConfig.DEFAULT_VARIANT
	end
	local lever = ExpeditionConfig.bossLever(catalog)
	if lever and variants[lever.name] then
		return lever.name
	end
	return LobbyConfig.DEFAULT_VARIANT
end

--- The lobby's expedition is a lever boss with a cloned lever room: started by pulling its lever.
function LobbyVariants.hasLeverRoom(record)
	return LobbyVariants.keyForRecord(record) ~= LobbyConfig.DEFAULT_VARIANT
end

--- Variant whose outer room (walls included) contains `pos`, if any.
function LobbyVariants.atPosition(pos)
	if not pos or pos.z ~= LobbyConfig.ROOM_Z then
		return nil
	end
	local dx, dy = pos.x - LobbyConfig.ROOM_BASE_X, pos.y - LobbyConfig.ROOM_BASE_Y
	if dx < 0 or dy < 0 then
		return nil
	end
	local stride = LobbyConfig.VARIANT_STRIDE
	local col, row = math.floor(dx / stride), math.floor(dy / stride)
	if col >= LobbyConfig.VARIANT_COLUMNS or dx % stride >= outerW() or dy % stride >= outerH() then
		return nil
	end
	return ordered[row * LobbyConfig.VARIANT_COLUMNS + col + 1]
end
