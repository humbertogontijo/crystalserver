-- The account-wide loot pouch replaces the stock Gold Pouch, so its store offer is hidden.
local startup = GlobalEvent("IdleotStoreOffers")

function startup.onStartup()
	for _, category in ipairs(GameStore.Categories or {}) do
		local offers = category.offers or {}
		for i = #offers, 1, -1 do
			if offers[i].itemtype == ITEM_GOLD_POUCH then
				table.remove(offers, i)
			end
		end
	end
	return true
end

startup:register()
