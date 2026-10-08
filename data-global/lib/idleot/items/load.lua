-- Apply CIP-derived NPC best prices onto ItemType (sellPrice / buyPrice).
-- Source: npc_offers.generated.lua (appearances npcSaleData).
-- CIP buy  → ItemType.sellPrice (NPC buys from player / hireling sell-all)
-- CIP sell → ItemType.buyPrice  (NPC sells to player / supply cost)

dofile(DATA_DIRECTORY .. "/lib/idleot/items/npc_offers.generated.lua")

NpcOffers = NpcOffers or {}
NpcOffers.byClientId = NpcOffersByClientId or {}

local function countKeys(t)
	local n = 0
	for _ in pairs(t) do
		n = n + 1
	end
	return n
end

local function applyNpcOfferPrices()
	local appliedSell, appliedBuy = 0, 0
	for clientId, entry in pairs(NpcOffers.byClientId) do
		local bestBuy = math.floor(tonumber(entry.bestBuy) or 0)
		local bestSell = math.floor(tonumber(entry.bestSell) or 0)
		if bestBuy > 0 or bestSell > 0 then
			local ok, itemType = pcall(ItemType, clientId)
			if ok and itemType and itemType:getId() > 0 then
				if bestBuy > 0 then
					local current = math.floor(tonumber(itemType:getSellPrice()) or 0)
					if bestBuy > current then
						itemType:setSellPrice(bestBuy)
						appliedSell = appliedSell + 1
					end
				end
				if bestSell > 0 then
					local current = math.floor(tonumber(itemType:getBuyPrice()) or 0)
					if bestSell > current then
						itemType:setBuyPrice(bestSell)
						appliedBuy = appliedBuy + 1
					end
				end
			end
		end
	end
	print(string.format(
		"[idleot/items] CIP NPC prices applied sell=%d buy=%d items=%d",
		appliedSell,
		appliedBuy,
		countKeys(NpcOffers.byClientId)
	))
end

applyNpcOfferPrices()
