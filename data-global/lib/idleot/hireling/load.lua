dofile(DATA_DIRECTORY .. "/lib/idleot/hireling/shop_items.lua")
dofile(DATA_DIRECTORY .. "/lib/idleot/hireling/buy_loot.lua")
dofile(DATA_DIRECTORY .. "/lib/idleot/hireling/sync.lua")
-- lamp_overlay.lua patches stock Hireling after core libs/systems/hireling.lua.
-- Loaded from scripts/idleot/hireling/lamp_overlay.lua (scripts run after libs).

-- Attach loot-sell catalog (Sell all is a client trade-UI button, not a row).
if HirelingShopItems and HirelingBuyLootItems then
	HirelingShopItems["buy loot"] = HirelingBuyLootItems
end

local LOOT_POUCH_CLIENT_ID = ITEM_GOLD_POUCH or 23721

--- One inventory walk → set of type ids the player currently holds.
--- Avoids getItemCount() × full loot catalog (1000+ recursive scans).
local function collectOwnedItemIds(player)
	local owned = {}
	if not player then
		return owned
	end

	local function scan(item)
		if not item then
			return
		end
		owned[item:getId()] = true
		if item.getClientId then
			local clientId = item:getClientId()
			if clientId and clientId > 0 then
				owned[clientId] = true
			end
		end
		if item.isContainer and item:isContainer() then
			local size = item:getSize() or 0
			for i = 0, size - 1 do
				scan(item:getItem(i))
			end
		end
	end

	for slot = CONST_SLOT_FIRST, CONST_SLOT_LAST do
		scan(player:getSlotItem(slot))
	end

	-- Loot / gold pouch often lives in the Store inbox, outside normal slots.
	if player.getStoreInbox then
		scan(player:getStoreInbox())
	elseif player.findItemInInbox then
		scan(player:findItemInInbox(LOOT_POUCH_CLIENT_ID))
	end

	return owned
end

--- Shrink a sell catalog to owned items only.
--- Full HirelingBuyLootItems (~1350 rows) freezes OTC when opening trade.
function HirelingShopItems.filterSellCatalogForPlayer(player, catalog)
	catalog = catalog or HirelingShopItems["buy loot"] or {}
	if not player then
		return catalog
	end

	local owned = collectOwnedItemIds(player)
	local filtered = {}

	for _, entry in ipairs(catalog) do
		if owned[entry.clientId] then
			filtered[#filtered + 1] = entry
		end
	end

	return filtered
end

--- Default remote/home trade window: owned loot only so Sell opens without freezing.
--- Buy categories stay available via chat ({various}, {equipment}, ...).
function HirelingShopItems.buildDefaultTradeShop(player)
	return HirelingShopItems.filterSellCatalogForPlayer(player, HirelingShopItems["buy loot"])
end
