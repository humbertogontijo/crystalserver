dofile(DATA_DIRECTORY .. "/lib/idleot/hireling/shop_items.lua")
dofile(DATA_DIRECTORY .. "/lib/idleot/hireling/buy_loot.generated.lua")
dofile(DATA_DIRECTORY .. "/lib/idleot/hireling/sync.lua")

-- Attach loot-sell catalog (Sell all is a client trade-UI button, not a row).
if HirelingShopItems and HirelingBuyLootItems then
	HirelingShopItems["buy loot"] = HirelingBuyLootItems
end

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
		if item:isContainer() then
			local size = item:getSize() or 0
			for i = 0, size - 1 do
				scan(item:getItem(i))
			end
		end
	end

	for slot = CONST_SLOT_FIRST, CONST_SLOT_LAST do
		scan(player:getSlotItem(slot))
	end

	-- Gold Pouch in store inbox (Crystal upstream getLootPouch).
	scan(player:getLootPouch())

	return owned
end

--- Shrink a sell catalog to owned items only.
--- Full HirelingBuyLootItems freezes OTC when opening trade.
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
