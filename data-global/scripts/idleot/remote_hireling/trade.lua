-- remote hireling trader + banker + sell loot pouch (opcode 115).
-- Dialog UI is game_remote_dialog (opcode 120): we bind the off-map trader NPC and
-- forward player lines as real TALKTYPE_PRIVATE_PN via RemoteDialog.

local REMOTE_HIRELING_OPCODE = 115
local NPC_TYPE_NAME = "Remote Hireling Trader"
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
			'{"type":"status","cooldownUntil":%d,"taxPercent":%d,"autoSell":%s,"sellOnNoGold":%s,"sellOnNoCap":%s,"acceptTaxOnCooldown":%s,"cooldownSeconds":%d}',
			tonumber(payload.cooldownUntil) or 0,
			tonumber(payload.taxPercent) or 0,
			payload.autoSell and "true" or "false",
			payload.sellOnNoGold and "true" or "false",
			payload.sellOnNoCap and "true" or "false",
			payload.acceptTaxOnCooldown and "true" or "false",
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

local function handleSellAll(player, payload)
	if not RemoteHirelingEconomy or not RemoteHirelingEconomy.sellAll then
		reply(player, { type = "error", message = "Auto-sell is unavailable." })
		return
	end

	local ignoreEquipped = payload.ignoreEquipped ~= false
	local filterMode = tonumber(payload.filterMode) == 1 and 1 or 0
	local itemIds = toItemIds(payload.itemIds)

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

local function handleSetAutoSell(player, payload)
	if not RemoteHirelingEconomy then
		return
	end
	local enabled = payload.enabled == true or payload.enabled == 1 or payload.enabled == "true"
	RemoteHirelingEconomy.setAutoSell(player, enabled)
	pushStatus(player)
	local msg = enabled and "Auto-sell enabled." or "Auto-sell disabled."
	player:sendTextMessage(MESSAGE_STATUS, msg)
	reply(player, { type = "ok", message = msg })
end

local function handleSetAutoSellConfig(player, payload)
	if not RemoteHirelingEconomy then
		return
	end
	if payload.sellOnNoGold ~= nil then
		RemoteHirelingEconomy.setSellOnNoGold(player, payload.sellOnNoGold == true or payload.sellOnNoGold == 1)
	end
	if payload.sellOnNoCap ~= nil then
		RemoteHirelingEconomy.setSellOnNoCap(player, payload.sellOnNoCap == true or payload.sellOnNoCap == 1)
	end
	if payload.acceptTaxOnCooldown ~= nil then
		RemoteHirelingEconomy.setAcceptTaxOnCooldown(
			player,
			payload.acceptTaxOnCooldown == true or payload.acceptTaxOnCooldown == 1
		)
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
	-- One off-map trader shared by every instance (dialogs are remote), so it lives in World.
	if tile and not tile:getGround() then
		Game.createItem(LobbyConfig.ROOM_FLOOR_ID, 1, REMOTE_NPC_POS, Instance.WORLD)
	end

	local npc = Game.createNpc(NPC_TYPE_NAME, REMOTE_NPC_POS, false, false, Instance.WORLD)
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

--- Manual SELL / Sell All: same filtered hireling-catalog path as emergency auto-sell.
local function handleSellLootPouch(player)
	if not RemoteHirelingEconomy or not RemoteHirelingEconomy.sellLootPouch then
		reply(player, { type = "error", message = "Auto-sell is unavailable." })
		return
	end

	local filterMode, itemIds = RemoteHirelingEconomy.getSellFilter(player)
	if filterMode == 1 and (not itemIds or #itemIds == 0) then
		local msg = "Accepted sell list is empty — add items or switch to Skipped."
		player:sendTextMessage(MESSAGE_STATUS, msg)
		reply(player, { type = "error", message = msg })
		pushStatus(player)
		return
	end

	local gold, items, taxPercent = RemoteHirelingEconomy.sellLootPouch(player, filterMode, itemIds)
	if items <= 0 or gold <= 0 then
		local msg = "No sellable junk in the loot pouch (check sell list / hireling catalog)."
		player:sendTextMessage(MESSAGE_FAILURE, msg)
		reply(player, { type = "error", message = msg })
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

local actionHandlers = {
	openRemoteHirelingTrade = function(player)
		openRemoteHirelingTrade(player)
		pushStatus(player)
	end,
	sellAll = handleSellAll,
	setAutoSell = handleSetAutoSell,
	setAutoSellConfig = handleSetAutoSellConfig,
	status = pushStatus,
	depositAll = depositAll,
	withdraw = function(player, payload)
		withdrawAmount(player, tonumber(payload.amount) or 0)
	end,
	sellLootPouch = handleSellLootPouch,
	bankStatus = bankStatus,
}

local opcodeEvent = CreatureEvent("RemoteHirelingOpcode")

function opcodeEvent.onExtendedOpcode(player, opcode, buffer)
	if opcode ~= REMOTE_HIRELING_OPCODE then
		return
	end
	if type(buffer) ~= "string" or buffer == "" then
		return
	end
	local payload = JsonParser.decode(buffer)
	local handler = type(payload) == "table" and actionHandlers[payload.action]
	if handler then
		handler(player, payload)
	end
end

opcodeEvent:register()
