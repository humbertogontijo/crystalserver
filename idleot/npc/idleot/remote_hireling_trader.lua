-- Remote hireling trader: same shop categories as house hirelings, no house gate.
-- In-home instances spawn a visible NPC; top-bar remote trade uses a shared off-map NPC
-- (see scripts/remote_hireling/trade.lua) so nothing appears next to the player.

local internalNpcName = "Remote Hireling Trader"
local npcType = Game.createNpcType(internalNpcName)
local npcConfig = {}

npcConfig.name = "Hireling Trader"
npcConfig.description = "a hireling trader"

npcConfig.health = 100
npcConfig.maxHealth = npcConfig.health
npcConfig.walkInterval = 0
npcConfig.walkRadius = 1

npcConfig.outfit = {
	lookType = 1111,
	lookHead = 97,
	lookBody = 34,
	lookLegs = 3,
	lookFeet = 116,
	lookAddons = 0,
}

npcConfig.flags = {
	floorchange = false,
	profession = "trader",
}
-- Not SPEECHBUBBLE_HIRELING (avoids house-invite C++ speak gate).
npcConfig.speechBubble = SPEECHBUBBLE_TRADE

local keywordHandler = KeywordHandler:new()
local npcHandler = NpcHandler:new(keywordHandler)
-- World-range talk so top-bar remote dialog works without a local spawn.
npcHandler:setTalkRange(250000)
-- Stock isInRange() uses isInTalkRange → canInteract, which requires the same floor.
-- Remote top-bar talk must work from any floor/position.
function npcHandler:isInRange(npc, player)
	return npc ~= nil and player ~= nil
end
-- Used by scripts/remote_hireling/trade.lua to greet like the player said "hi".
RemoteHirelingTraderHandler = npcHandler
local itemsTable = HirelingShopItems

local GOODS_TEXT =
	"I sell a selection of {various} items, {exercise weapons}, {equipment}, "
	.. "{distance} weapons, {wands} and {rods}, {potions}, {runes}, "
	.. "{supplies}, {tools} and {postal} goods. I can also {buy loot}. Just ask!"

local function openSellShop(npc, player, catalog, applyRemoteTax)
	local shop = catalog
	if HirelingShopItems.filterSellCatalogForPlayer then
		shop = HirelingShopItems.filterSellCatalogForPlayer(player, catalog)
	elseif HirelingShopItems.buildDefaultTradeShop then
		shop = HirelingShopItems.buildDefaultTradeShop(player)
	end
	shop = shop or HirelingShopItems["various"]
	-- Remote path (top-bar / RemoteDialog): bake tax into sell prices so stock
	-- Sell / Sell all pay net gold. In-home talks leave applyRemoteTax false.
	if applyRemoteTax and RemoteHirelingEconomy and shop then
		local tax = RemoteHirelingEconomy.getTaxPercent(player)
		if tax > 0 then
			shop = RemoteHirelingEconomy.applyTaxToCatalog(shop, tax)
		end
	end
	if shop then
		npc:openShopWindowTable(player, shop)
		return true
	end
	return false
end

local function openDefaultShop(npc, player, applyRemoteTax)
	local catalog = HirelingShopItems["buy loot"] or HirelingShopItems["various"]
	return openSellShop(npc, player, catalog, applyRemoteTax == true)
end

--- Top-bar remote trade: open the sell shop immediately after the dialog binds.
function RemoteHirelingOpenDefaultShop(npc, player)
	if not npc or not player then
		return false
	end
	local opened = openDefaultShop(npc, player, true)
	if opened then
		npcHandler:say(GOODS_TEXT, npc, player)
	end
	return opened
end

--- Refresh an already-open remote shop after cooldown starts (bake in tax).
function RemoteHirelingRefreshTaxedShop(npc, player)
	if not npc or not player then
		return false
	end
	return openDefaultShop(npc, player, true)
end

npcType.onThink = function(npc, interval)
	npcHandler:onThink(npc, interval)
end

npcType.onAppear = function(npc, creature)
	npcHandler:onAppear(npc, creature)
end

npcType.onDisappear = function(npc, creature)
	npcHandler:onDisappear(npc, creature)
end

npcType.onMove = function(npc, creature, fromPosition, toPosition)
	npcHandler:onMove(npc, creature, fromPosition, toPosition)
end

npcType.onSay = function(npc, creature, type, message)
	npcHandler:onSay(npc, creature, type, message)
end

npcType.onCloseChannel = function(npc, creature)
	npcHandler:onCloseChannel(npc, creature)
end

local function creatureSayCallback(npc, creature, type, message)
	local player = creature
	if not player or not player:isPlayer() then
		return false
	end

	if not npcHandler:checkInteraction(npc, player) then
		return false
	end

	local lower = message:lower()
	-- List categories only (shop opens via {buy loot} / other categories or FocusModule trade).
	if MsgContains(message, "goods") or MsgContains(message, "shop options") then
		npcHandler:say(GOODS_TEXT, npc, creature)
		return true
	end

	local categoryTable = itemsTable[lower]
	if categoryTable then
		local remainingCategories = npc:getRemainingShopCategories(lower, itemsTable)
		npcHandler:say(
			"Of course, just browse through my wares. You can also look at " .. remainingCategories .. ".",
			npc,
			creature
		)
		-- "buy loot" is ~1350 sell rows; only send what the player can sell.
		if lower == "buy loot" then
			local remote = RemoteDialog and RemoteDialog.isOpen and RemoteDialog.isOpen(player)
			openSellShop(npc, player, categoryTable, remote == true)
		else
			npc:openShopWindowTable(player, categoryTable)
		end
		return true
	end


	return true
end

-- After greet, "trade"/"offers" opens the sell-focused loot shop (same as saying {buy loot}).
npcHandler:setCallback(CALLBACK_ON_TRADE_REQUEST, function(npc, player, message)
	local remote = RemoteDialog and RemoteDialog.isOpen and RemoteDialog.isOpen(player)
	openDefaultShop(npc, player, remote == true)
	npcHandler:say(GOODS_TEXT, npc, player)
	return false
end)

npcHandler:setMessage(MESSAGE_GREET, "It is good to see you. I'm always at your {goods}.")
npcHandler:setMessage(MESSAGE_FAREWELL, "Farewell, |PLAYERNAME|. Call me again when you need supplies.")
npcHandler:setMessage(MESSAGE_WALKAWAY, "Come back soon!")
npcHandler:setMessage(MESSAGE_SENDTRADE, GOODS_TEXT)

npcHandler:setCallback(CALLBACK_MESSAGE_DEFAULT, creatureSayCallback)
npcHandler:addModule(FocusModule:new(), npcConfig.name, true, true, true)

npcType.onBuyItem = function(npc, player, itemId, subType, amount, ignore, inBackpacks, totalCost)
	npc:sellItem(player, itemId, amount, subType, 0, ignore, inBackpacks)
end

npcType.onSellItem = function(npc, player, itemId, subtype, amount, ignore, name, totalCost)
	local remote = RemoteDialog and RemoteDialog.isOpen and RemoteDialog.isOpen(player)
	if remote and RemoteHirelingEconomy and totalCost and totalCost > 0 then
		if not RemoteHirelingEconomy.isOnCooldown(player) then
			-- First free remote shop sell starts the hour cooldown. Remaining
			-- chunks in the same Sell all keep the open (free) shop vector.
			RemoteHirelingEconomy.startCooldownIfFree(player)
			if RemoteHirelingPushStatus then
				RemoteHirelingPushStatus(player)
			end
		end
	end
	player:sendTextMessage(MESSAGE_TRADE, string.format("Sold %ix %s for %i gold.", amount, name, totalCost))
end

npcType.onCheckItem = function(npc, player, clientId, subType) end

npcType:register(npcConfig)
