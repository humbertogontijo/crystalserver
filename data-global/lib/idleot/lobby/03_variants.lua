-- Lobby room variants: identical stamped rooms (walls, floor, fixtures) laid out in a grid,
-- differing only in the CENTER_SIZE center. The default variant keeps plain floor; each lever
-- boss gets a variant whose center is a clone of its real lever room (ground, fixed decor,
-- slots, lever) framed by CENTER_BORDER overlays. Grounds cannot differ per instance, so a
-- lobby switches rooms by moving its private fence (LobbyInstance.applyVariant). The map
-- stamping itself: 03_room_stamp.lua.
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
	for _, entry in ipairs(ExpeditionConfig.Catalog or {}) do
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
	LobbyRoomStamp.shell(register(LobbyConfig.DEFAULT_VARIANT, 0))
	local index, skipped = 1, 0
	for _, lever in ipairs(catalogLevers()) do
		local variant = register(lever.name, index, { bossName = lever.name })
		LobbyRoomStamp.shell(variant)
		if LobbyRoomStamp.leverCenter(variant, lever) then
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
