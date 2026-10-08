-- Bulk NPC sell-all (opcode 123).
-- Client JSON: { "action": "sellAll", "ignoreEquipped": true, "filterMode": 0|1, "itemIds": [...], "lootPouchOnly": true }
-- filterMode 0 = skipped (sell all except list), 1 = accepted (sell only list).

local NPCSELL_OPCODE = 123

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

	local payload = JsonParser.decode(buffer)
	if type(payload) ~= "table" or payload.action ~= "sellAll" then
		return
	end

	if not player.sellAllShopItems then
		player:sendTextMessage(MESSAGE_FAILURE, "Sell all is unavailable on this server build.")
		return
	end

	local ignoreEquipped = payload.ignoreEquipped ~= false
	local lootPouchOnly = payload.lootPouchOnly ~= false
	local filterMode = tonumber(payload.filterMode) == 1 and 1 or 0
	local itemIds = IdleUtil.toItemIds(payload.itemIds)

	player:sellAllShopItems(ignoreEquipped, filterMode, itemIds, lootPouchOnly)
end

opcodeEvent:register()
