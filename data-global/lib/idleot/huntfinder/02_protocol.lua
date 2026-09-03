-- Hunt Finder opcode 252: monster stats + item id lookup for the OTC detail panel.
-- Client request:  { action = "allMonsterInfo", monsters = { "Rat", ... } }
--                   { action = "itemIds", items = { "great health potion", ... } }
-- Client response: { action = "allMonsterInfo", data = { [name] = { raceId, health, experience, speed, armor, mitigation, elements } } }
--                   { action = "itemIds", data = { [name] = itemId } }
-- Element keys match bestiary / OTC huntfinder (0=physical … 7=healing); values are 100 - absorb%.

HuntFinderProtocol = HuntFinderProtocol or {}

local ELEMENT_INDEX = {
	[COMBAT_PHYSICALDAMAGE] = 0,
	[COMBAT_FIREDAMAGE] = 1,
	[COMBAT_EARTHDAMAGE] = 2,
	[COMBAT_ENERGYDAMAGE] = 3,
	[COMBAT_ICEDAMAGE] = 4,
	[COMBAT_HOLYDAMAGE] = 5,
	[COMBAT_DEATHDAMAGE] = 6,
	[COMBAT_HEALING] = 7,
}

local function encode(payload)
	if ExpeditionJson and ExpeditionJson.encode then
		return ExpeditionJson.encode(payload)
	end
	return nil
end

local function decode(buffer)
	if ExpeditionJson and ExpeditionJson.decode then
		local ok, decoded = pcall(ExpeditionJson.decode, buffer)
		if ok and type(decoded) == "table" then
			return decoded
		end
	end
	return nil
end

local function send(player, payload)
	if not player or not HuntFinderConfig then
		return false
	end
	local encoded = encode(payload)
	if not encoded then
		return false
	end
	return player:sendExtendedOpcode(HuntFinderConfig.OPCODE, encoded)
end

local function collectNames(raw)
	local out = {}
	local seen = {}
	if type(raw) ~= "table" then
		return out
	end
	local maxNames = (HuntFinderConfig and HuntFinderConfig.MAX_NAMES) or 64
	for _, value in ipairs(raw) do
		if type(value) == "string" then
			local name = value:match("^%s*(.-)%s*$") or ""
			if name ~= "" and not seen[name:lower()] then
				seen[name:lower()] = true
				out[#out + 1] = name
				if #out >= maxNames then
					break
				end
			end
		end
	end
	return out
end

local function bestiaryElements(mType)
	local elements = {}
	for i = 0, 7 do
		elements[i] = 100
	end
	local list = mType:getElementList()
	if type(list) ~= "table" then
		return elements
	end
	for combatType, percent in pairs(list) do
		local index = ELEMENT_INDEX[tonumber(combatType)]
		if index ~= nil then
			elements[index] = 100 - (tonumber(percent) or 0)
		end
	end
	return elements
end

local function monsterInfo(name)
	local mType = MonsterType(name)
	if not mType then
		return nil
	end
	local raceId = mType:raceId() or 0
	if raceId == 0 then
		return nil
	end
	return {
		raceId = raceId,
		health = mType:maxHealth() or mType:health() or 0,
		experience = mType:experience() or 0,
		speed = mType:baseSpeed() or 0,
		armor = mType:armor() or 0,
		mitigation = mType:mitigation() or 0,
		elements = bestiaryElements(mType),
	}
end

local function itemIdByName(name)
	if type(name) ~= "string" or name == "" then
		return 0
	end
	local ok, itemType = pcall(ItemType, name)
	if not ok or not itemType then
		return 0
	end
	local id = itemType:getId()
	return (id and id > 0) and id or 0
end

function HuntFinderProtocol.handleAllMonsterInfo(player, names)
	local data = {}
	for _, name in ipairs(names) do
		local info = monsterInfo(name)
		if info then
			data[name] = info
		end
	end
	send(player, { action = "allMonsterInfo", data = data })
end

function HuntFinderProtocol.handleItemIds(player, names)
	local data = {}
	for _, name in ipairs(names) do
		local id = itemIdByName(name)
		if id > 0 then
			data[name] = id
		end
	end
	send(player, { action = "itemIds", data = data })
end

function HuntFinderProtocol.handle(player, buffer)
	if not player or type(buffer) ~= "string" or buffer == "" then
		return
	end
	local payload = decode(buffer)
	if type(payload) ~= "table" then
		return
	end
	local action = payload.action
	if action == "allMonsterInfo" then
		HuntFinderProtocol.handleAllMonsterInfo(player, collectNames(payload.monsters))
		return
	end
	if action == "itemIds" then
		HuntFinderProtocol.handleItemIds(player, collectNames(payload.items))
		return
	end
end
