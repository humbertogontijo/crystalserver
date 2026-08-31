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
			'{"type":"sold","gold":%d,"items":%d,"message":%s}',
			tonumber(payload.gold) or 0,
			tonumber(payload.items) or 0,
			escapeStr(payload.message or "")
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

	player:addMoney(totalGold)
	local msg = string.format("Sold %d items for %d gold.", soldItems, totalGold)
	player:sendTextMessage(MESSAGE_EVENT_ADVANCE, msg)
	reply(player, { type = "sold", gold = totalGold, items = soldItems, message = msg })
end

local loginEvent = CreatureEvent("RemoteHirelingLogin")

function loginEvent.onLogin(player)
	player:registerEvent("RemoteHirelingOpcode")
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
	local action = buffer:match('"action"%s*:%s*"([^"]+)"')
	if action == "openRemoteHirelingTrade" or buffer:find('"openRemoteHirelingTrade"', 1, true) then
		openRemoteHirelingTrade(player)
		return
	end
	if action == "depositAll" or buffer:find('"depositAll"', 1, true) then
		depositAll(player)
		return
	end
	if action == "withdraw" or buffer:find('"withdraw"', 1, true) then
		local amount = tonumber(buffer:match('"amount"%s*:%s*(%d+)')) or 0
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
