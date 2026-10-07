-- Crystal Auto Loot feature default.
-- Server death path: Creature death → dropLoot → LootSplit (multi-account party) →
--   async Game::playerQuickLootCorpse for getAutoLootPlayer (companions → controller).
-- Unassigned (OBJECTCATEGORY_DEFAULT=31) is hard-locked to loot pouch (ITEM_GOLD_POUCH) in C++.

local loginEvent = CreatureEvent("AutoLootLogin")

function loginEvent.onLogin(player)
	-- Config alone is not enough: checkAutoLoot requires features.autoloot KV 1/2.
	-- Default-enable regular kills when AUTOLOOT is on.
	if configManager.getBoolean(configKeys.AUTOLOOT) then
		local current = player:getFeature(Features.AutoLoot)
		if current == nil or current == 0 then
			player:setFeature(Features.AutoLoot, 1)
		end
	end
	return true
end

loginEvent:register()
