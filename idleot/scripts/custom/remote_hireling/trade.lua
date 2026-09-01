-- remote hireling trader + banker + sell loot pouch (opcode 115).
-- Dialog UI is game_remote_dialog (opcode 120): we bind the off-map trader NPC and
-- forward player lines as real TALKTYPE_PRIVATE_PN via RemoteDialog.

local REMOTE_HIRELING_OPCODE = 115
local NPC_TYPE_NAME = "Remote Hireling Trader"
local LOOT_POUCH_ID = ITEM_GOLD_POUCH or 23721
local REMOTE_NPC_POS = Position(63990, 63990, 7)

local HIRELING_OUTFIT = {
	type = 1111,
	head = 97,
	body = 34,
	legs = 3,
	feet = 116,
	addons = 0,
}

local HIRELING_BUTTONS = {
	{ id = 0, text = "goods" },
	{ id = 1, text = "trade" },
	{ id = 2, text = "buy loot" },
	{ id = 9, text = "bye" },
}

--- @type number|nil
local remoteNpcId = nil

local function escapeStr(s)
	s = tostring(s or "")
	s = s:gsub("\\", "\\\\")
	s = s:gsub('"', '\\"')
	s = s:gsub("\n", "\\n")
	s = s:gsub("\r", "\\r")
	s = s:gsub("\t", "\\t")
	return '"' .. s .. '"'
end

local function encodeJson(payload)
	if payload.type == "bank" then
		return string.format(
			'{"type":"bank","balance":%d,"inventory":%d,"message":%s}',
			tonumber(payload.balance) or 0,
			tonumber(payload.inventory) or 0,
			escapeStr(payload.message or "")
		)
	end
	if payload.type == "sold" then
		return string.format(
			'{"type":"sold","gold":%d,"items":%d,"taxPercent":%d,"message":%s}',
			tonumber(payload.gold) or 0,
			tonumber(payload.items) or 0,
			tonumber(payload.taxPercent) or 0,
			escapeStr(payload.message or "")
		)
	end
	if payload.type == "status" then
		return string.format(
			'{"type":"status","cooldownUntil":%d,"taxPercent":%d,"autoSell":%s,"sellOnNoGold":%s,"sellOnNoCap":%s,"cooldownSeconds":%d}',
			tonumber(payload.cooldownUntil) or 0,
			tonumber(payload.taxPercent) or 0,
			payload.autoSell and "true" or "false",
			payload.sellOnNoGold and "true" or "false",
			payload.sellOnNoCap and "true" or "false",
			tonumber(payload.cooldownSeconds) or 3600
		)
	end
	if payload.type == "ok" then
		return '{"type":"ok","message":' .. escapeStr(payload.message or "") .. "}"
	end
	return '{"type":"error","message":' .. escapeStr(payload.message or "error") .. "}"
end

local function reply(player, payload)
	player:sendExtendedOpcode(REMOTE_HIRELING_OPCODE, encodeJson(payload))
end

local function pushStatus(player)
	if not player or not RemoteHirelingEconomy then
		return
	end
	local fields = RemoteHirelingEconomy.statusFields(player)
	fields.type = "status"
	reply(player, fields)
end

function RemoteHirelingPushStatus(player)
	pushStatus(player)
end

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

local function handleSellAll(player, payload, buffer)
	if not RemoteHirelingEconomy or not RemoteHirelingEconomy.sellAll then
		reply(player, { type = "error", message = "Auto-sell is unavailable." })
		return
	end

	local ignoreEquipped = true
	local filterMode = 0
	local itemIds = {}

	if type(payload) == "table" then
		if payload.ignoreEquipped == false then
			ignoreEquipped = false
		end
		filterMode = tonumber(payload.filterMode) or 0
		if filterMode ~= 1 then
			filterMode = 0
		end
		itemIds = toItemIds(payload.itemIds)
	else
		if buffer and buffer:find('"ignoreEquipped"%s*:%s*false', 1, false) then
			ignoreEquipped = false
		end
		filterMode = tonumber(buffer and buffer:match('"filterMode"%s*:%s*(%d+)')) or 0
		if filterMode ~= 1 then
			filterMode = 0
		end
	end

	local gold, items, taxPercent = RemoteHirelingEconomy.sellAll(player, ignoreEquipped, filterMode, itemIds)
	if RemoteHirelingEconomy.setSellFilter then
		RemoteHirelingEconomy.setSellFilter(player, filterMode, itemIds)
	end
	if items <= 0 or gold <= 0 then
		-- Silent when empty (auto-sell polls often).
		pushStatus(player)
		return
	end

	local msg
	if taxPercent > 0 then
		msg = string.format("Sold %d items for %d gold (%d%% remote tax).", items, gold, taxPercent)
	else
		msg = string.format("Sold %d items for %d gold.", items, gold)
	end
	player:sendTextMessage(MESSAGE_EVENT_ADVANCE, msg)
	reply(player, { type = "sold", gold = gold, items = items, taxPercent = taxPercent, message = msg })
	pushStatus(player)
end

local function handleSetAutoSell(player, payload, buffer)
	if not RemoteHirelingEconomy then
		return
	end
	local enabled = false
	if type(payload) == "table" then
		enabled = payload.enabled == true or payload.enabled == 1 or payload.enabled == "true"
	elseif buffer and buffer:find('"enabled"%s*:%s*true', 1, false) then
		enabled = true
	end
	RemoteHirelingEconomy.setAutoSell(player, enabled)
	pushStatus(player)
	local msg = enabled and "Auto-sell enabled." or "Auto-sell disabled."
	player:sendTextMessage(MESSAGE_STATUS, msg)
	reply(player, { type = "ok", message = msg })
end

local function handleSetAutoSellConfig(player, payload)
	if not RemoteHirelingEconomy or type(payload) ~= "table" then
		return
	end
	if payload.sellOnNoGold ~= nil then
		RemoteHirelingEconomy.setSellOnNoGold(player, payload.sellOnNoGold == true or payload.sellOnNoGold == 1)
	end
	if payload.sellOnNoCap ~= nil then
		RemoteHirelingEconomy.setSellOnNoCap(player, payload.sellOnNoCap == true or payload.sellOnNoCap == 1)
	end
	local filterMode = tonumber(payload.filterMode)
	if filterMode ~= nil then
		if filterMode ~= 1 then
			filterMode = 0
		end
		RemoteHirelingEconomy.setSellFilter(player, filterMode, toItemIds(payload.itemIds))
	end
	pushStatus(player)
	reply(player, { type = "ok", message = "Auto-sell options updated." })
end

local function ensureRemoteNpc()
	if remoteNpcId then
		local existing = Npc(remoteNpcId)
		if existing then
			return existing
		end
		remoteNpcId = nil
	end

	local tile = Tile(REMOTE_NPC_POS)
	if not tile then
		tile = Game.createTile(REMOTE_NPC_POS, true)
	end
	if tile and not tile:getGround() then
		local groundId = (PlayerHomeConfig and PlayerHomeConfig.FLOOR_ID) or 4526
		Game.createItem(groundId, 1, REMOTE_NPC_POS)
	end

	local npc = Game.createNpc(NPC_TYPE_NAME, REMOTE_NPC_POS)
	if not npc then
		return nil
	end
	if npc.setMasterPos then
		npc:setMasterPos(REMOTE_NPC_POS)
	end
	remoteNpcId = npc:getId()
	return npc
end

-- Home already spawns a hireling trader NPC; top-bar remote trade does not
-- require owned lamps, store hirelings, or hireling skills.

local function openRemoteHirelingTrade(player)
	if not player or not player:isPlayer() then
		return
	end

	if not HirelingShopItems or not (HirelingShopItems["buy loot"] or HirelingShopItems["various"]) then
		local msg = "Hireling shop catalog is unavailable."
		player:sendTextMessage(MESSAGE_FAILURE, msg)
		reply(player, { type = "error", message = msg })
		return
	end

	local npc = ensureRemoteNpc()
	if not npc then
		local msg = "Hireling trader is unavailable right now."
		player:sendTextMessage(MESSAGE_FAILURE, msg)
		reply(player, { type = "error", message = msg })
		return
	end

	if not RemoteDialog or not RemoteDialog.open then
		local msg = "Remote dialog system is unavailable."
		player:sendTextMessage(MESSAGE_FAILURE, msg)
		reply(player, { type = "error", message = msg })
		return
	end

	-- Bind the real hireling NPC: say → PRIVATE_PN → NpcHandler; replies are PRIVATE_NP.
	RemoteDialog.open(player, {
		id = "hireling",
		name = npc:getName() or "Hireling Trader",
		npc = npc,
		handler = RemoteHirelingTraderHandler,
		outfit = HIRELING_OUTFIT,
		buttons = HIRELING_BUTTONS,
		simulateHi = true,
	})

	-- Top-bar UX: open the sell shop as soon as the dialog UI is up (no extra Trade click).
	local pid = player:getId()
	local nid = npc:getId()
	addEvent(function()
		local p = Player(pid)
		local n = Npc(nid)
		if not p or not n or not RemoteDialog.isOpen(p) then
			return
		end
		if type(RemoteHirelingOpenDefaultShop) == "function" then
			RemoteHirelingOpenDefaultShop(n, p)
		end
	end, 250)
end

local function bankStatus(player)
	reply(player, {
		type = "bank",
		balance = player:getBankBalance() or 0,
		inventory = player:getMoney() or 0,
		message = "Bank balance ready.",
	})
end

local function depositAll(player)
	local money = player:getMoney() or 0
	if money <= 0 then
		local msg = "You have no inventory gold to deposit."
		player:sendTextMessage(MESSAGE_FAILURE, msg)
		reply(player, { type = "error", message = msg })
		return
	end
	if player.depositMoney then
		player:depositMoney(money)
	else
		if not player:removeMoney(money) then
			reply(player, { type = "error", message = "Could not remove gold." })
			return
		end
		player:setBankBalance((player:getBankBalance() or 0) + money)
	end
	local msg = string.format("Deposited %d gold.", money)
	player:sendTextMessage(MESSAGE_EVENT_ADVANCE, msg)
	reply(player, { type = "ok", message = msg })
	bankStatus(player)
end

local function withdrawAmount(player, amount)
	amount = math.floor(tonumber(amount) or 0)
	if amount <= 0 then
		amount = player:getBankBalance() or 0
	end
	if amount <= 0 then
		local msg = "Bank is empty."
		player:sendTextMessage(MESSAGE_FAILURE, msg)
		reply(player, { type = "error", message = msg })
		return
	end
	if player.withdrawMoney then
		if not player:withdrawMoney(amount) then
			local msg = "Not enough bank balance."
			player:sendTextMessage(MESSAGE_FAILURE, msg)
			reply(player, { type = "error", message = msg })
			return
		end
	else
		local bal = player:getBankBalance() or 0
		if amount > bal then
			reply(player, { type = "error", message = "Not enough bank balance." })
			return
		end
		-- Fall back without Bank.withdraw: only withdraw should create coin items.
		-- Prefer leaving gold in bank rather than calling addMoney (which banks again).
		local msg = "Withdraw requires Bank.withdrawMoney."
		player:sendTextMessage(MESSAGE_FAILURE, msg)
		reply(player, { type = "error", message = msg })
		return
	end
	local msg = string.format("Withdrew %d gold.", amount)
	player:sendTextMessage(MESSAGE_EVENT_ADVANCE, msg)
	reply(player, { type = "ok", message = msg })
	bankStatus(player)
end

local function findLootPouch(player)
	local pouch = nil
	if player.findItemInInbox and ITEM_GOLD_POUCH then
		pouch = player:findItemInInbox(ITEM_GOLD_POUCH)
	end
	if not pouch then
		pouch = player:getItemById(LOOT_POUCH_ID, true)
	end
	return pouch
end

local function sellPriceForItem(item)
	if not item then
		return 0
	end
	local clientId = item:getId()
	if item.getClientId then
		clientId = item:getClientId() or clientId
	end
	if NpcPriceChecker and NpcPriceChecker[clientId] and NpcPriceChecker[clientId].sell then
		return math.floor(tonumber(NpcPriceChecker[clientId].sell) or 0)
	end
	if NpcPriceChecker and NpcPriceChecker[item:getId()] and NpcPriceChecker[item:getId()].sell then
		return math.floor(tonumber(NpcPriceChecker[item:getId()].sell) or 0)
	end
	return 0
end

local function sellLootPouch(player)
	local pouch = findLootPouch(player)
	if not pouch or not pouch.isContainer or not pouch:isContainer() then
		local msg = "No loot pouch found."
		player:sendTextMessage(MESSAGE_FAILURE, msg)
		reply(player, { type = "error", message = msg })
		return
	end

	local totalGold = 0
	local soldItems = 0
	local toRemove = {}
	for i = pouch:getSize() - 1, 0, -1 do
		local it = pouch:getItem(i)
		if it then
			local price = sellPriceForItem(it)
			local count = it:getCount() or 1
			if price > 0 then
				totalGold = totalGold + price * count
				soldItems = soldItems + count
				toRemove[#toRemove + 1] = it
			end
		end
	end

	for _, it in ipairs(toRemove) do
		it:remove()
	end

	if totalGold <= 0 then
		local msg = "No sellable junk in the loot pouch (NPC sell prices)."
		player:sendTextMessage(MESSAGE_FAILURE, msg)
		reply(player, { type = "error", message = msg })
		return
	end

	local taxPercent = 0
	local netGold = totalGold
	if RemoteHirelingEconomy then
		taxPercent = RemoteHirelingEconomy.getTaxPercent(player)
		if taxPercent > 0 then
			netGold = math.floor(totalGold * (100 - taxPercent) / 100)
		end
	end

	player:addMoney(netGold)
	if taxPercent == 0 and netGold > 0 and RemoteHirelingEconomy then
		RemoteHirelingEconomy.startCooldownIfFree(player)
	end

	local msg
	if taxPercent > 0 then
		msg = string.format("Sold %d items for %d gold (%d%% remote tax).", soldItems, netGold, taxPercent)
	else
		msg = string.format("Sold %d items for %d gold.", soldItems, netGold)
	end
	player:sendTextMessage(MESSAGE_EVENT_ADVANCE, msg)
	reply(player, { type = "sold", gold = netGold, items = soldItems, taxPercent = taxPercent, message = msg })
	pushStatus(player)
end

local loginEvent = CreatureEvent("RemoteHirelingLogin")

function loginEvent.onLogin(player)
	player:registerEvent("RemoteHirelingOpcode")
	local pid = player:getId()
	-- Defer status so client opcode handlers are registered.
	addEvent(function()
		local p = Player(pid)
		if p then
			pushStatus(p)
		end
	end, 500)
	return true
end

loginEvent:register()

local opcodeEvent = CreatureEvent("RemoteHirelingOpcode")

function opcodeEvent.onExtendedOpcode(player, opcode, buffer)
	if opcode ~= REMOTE_HIRELING_OPCODE then
		return
	end
	if type(buffer) ~= "string" or buffer == "" then
		return
	end
	local payload = decodePayload(buffer)
	local action = (payload and payload.action) or buffer:match('"action"%s*:%s*"([^"]+)"')
	if action == "openRemoteHirelingTrade" or buffer:find('"openRemoteHirelingTrade"', 1, true) then
		openRemoteHirelingTrade(player)
		pushStatus(player)
		return
	end
	if action == "sellAll" or buffer:find('"sellAll"', 1, true) then
		handleSellAll(player, payload, buffer)
		return
	end
	if action == "setAutoSell" or buffer:find('"setAutoSell"', 1, true) then
		handleSetAutoSell(player, payload, buffer)
		return
	end
	if action == "setAutoSellConfig" or buffer:find('"setAutoSellConfig"', 1, true) then
		handleSetAutoSellConfig(player, payload)
		return
	end
	if action == "status" or buffer:find('"status"', 1, true) then
		pushStatus(player)
		return
	end
	if action == "depositAll" or buffer:find('"depositAll"', 1, true) then
		depositAll(player)
		return
	end
	if action == "withdraw" or buffer:find('"withdraw"', 1, true) then
		local amount = tonumber((payload and payload.amount) or buffer:match('"amount"%s*:%s*(%d+)')) or 0
		withdrawAmount(player, amount)
		return
	end
	if action == "sellLootPouch" or buffer:find('"sellLootPouch"', 1, true) then
		sellLootPouch(player)
		return
	end
	if action == "bankStatus" or buffer:find('"bankStatus"', 1, true) then
		bankStatus(player)
		return
	end
end

opcodeEvent:register()
