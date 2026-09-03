-- Bulk NPC sell-all (opcode 123).
-- Client JSON: { "action": "sellAll", "ignoreEquipped": true, "filterMode": 0|1, "itemIds": [...], "lootPouchOnly": true }
-- filterMode 0 = skipped (sell all except list), 1 = accepted (sell only list).

local NPCSELL_OPCODE = 123

local function decodePayload(buffer)
	if ExpeditionJson and ExpeditionJson.decode then
		local ok, decoded = pcall(ExpeditionJson.decode, buffer)
		if ok and type(decoded) == "table" then
			return decoded
		end
	end
	return nil
end

local function toItemIds(raw)
	local out = {}
	if type(raw) ~= "table" then
		return out
	end
	for _, value in ipairs(raw) do
		local id = tonumber(value)
		if id and id > 0 then
			out[#out + 1] = math.floor(id)
			if #out >= 512 then
				break
			end
		end
	end
	return out
end

local loginEvent = CreatureEvent("NpcSellLogin")

function loginEvent.onLogin(player)
	player:registerEvent("NpcSellOpcode")
	return true
end

loginEvent:register()

local opcodeEvent = CreatureEvent("NpcSellOpcode")

function opcodeEvent.onExtendedOpcode(player, opcode, buffer)
	if opcode ~= NPCSELL_OPCODE then
		return
	end
	if type(buffer) ~= "string" or buffer == "" then
		return
	end

	local payload = decodePayload(buffer)
	local action = payload and payload.action or buffer:match('"action"%s*:%s*"([^"]+)"')
	if action ~= "sellAll" then
		return
	end

	if not player.sellAllShopItems then
		player:sendTextMessage(MESSAGE_FAILURE, "Sell all is unavailable on this server build.")
		return
	end

	local ignoreEquipped = true
	local filterMode = 0
	local itemIds = {}
	local lootPouchOnly = true

	if type(payload) == "table" then
		if payload.ignoreEquipped == false then
			ignoreEquipped = false
		end
		if payload.lootPouchOnly == false then
			lootPouchOnly = false
		end
		filterMode = tonumber(payload.filterMode) or 0
		if filterMode ~= 1 then
			filterMode = 0
		end
		itemIds = toItemIds(payload.itemIds)
	else
		if buffer:find('"ignoreEquipped"%s*:%s*false', 1, false) then
			ignoreEquipped = false
		end
		if buffer:find('"lootPouchOnly"%s*:%s*false', 1, false) then
			lootPouchOnly = false
		end
		filterMode = tonumber(buffer:match('"filterMode"%s*:%s*(%d+)')) or 0
		if filterMode ~= 1 then
			filterMode = 0
		end
	end

	player:sellAllShopItems(ignoreEquipped, filterMode, itemIds, lootPouchOnly)
end

opcodeEvent:register()
