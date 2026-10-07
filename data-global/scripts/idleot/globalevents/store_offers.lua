-- The account-wide loot pouch replaces the stock Gold Pouch, so its store offer is hidden.
-- Product offers (lib/idleot/store) are appended to their stock categories.
local startup = GlobalEvent("IdleotStoreOffers")

local function findCategory(name)
	for _, category in ipairs(GameStore.Categories or {}) do
		if category.name == name then
			return category
		end
	end
	return nil
end

function startup.onStartup()
	for _, category in ipairs(GameStore.Categories or {}) do
		local offers = category.offers or {}
		for i = #offers, 1, -1 do
			if offers[i].itemtype == ITEM_GOLD_POUCH then
				table.remove(offers, i)
			end
		end
	end

	for categoryName, offers in pairs(IdleotStore.buildOffers()) do
		local category = findCategory(categoryName)
		if category then
			category.offers = category.offers or {}
			for _, offer in ipairs(offers) do
				table.insert(category.offers, offer)
			end
		else
			logger.warn("[IdleotStoreOffers] store category '{}' not found", categoryName)
		end
	end
	return true
end

startup:register()
