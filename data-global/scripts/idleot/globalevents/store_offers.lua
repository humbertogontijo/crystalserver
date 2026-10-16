-- Product offers (lib/idleot/store) are appended to their stock categories.
-- Stock Gold Pouch (store inbox, once) stays buyable — Crystal upstream behavior.
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
