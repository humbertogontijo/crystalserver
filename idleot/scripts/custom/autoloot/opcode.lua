-- Crystal Auto Loot bridge (opcode + feature defaults).
-- Loot pouch is granted once on first login via SendFirstItems (product overlay).
-- Client extended opcode 114, JSON: { "action": "setAutoLoot", "mode": "on"|"off"|"all" }
-- Server death path: Creature death → dropLoot → LootSplit (multi-account party) →
--   async Game::playerQuickLootCorpse for getAutoLootPlayer (companions → controller).
-- Unassigned (OBJECTCATEGORY_DEFAULT=31) is hard-locked to loot pouch (ITEM_GOLD_POUCH) in C++.

local AUTOLOOT_OPCODE = 114

local loginEvent = CreatureEvent("AutoLootLogin")

function loginEvent.onLogin(player)
	player:registerEvent("AutoLootOpcode")
	-- Config alone is not enough: checkAutoLoot requires features.autoloot KV 1/2.
	-- Default-enable regular kills when AUTOLOOT is on; client opcode 114 can still turn it off.
	if configManager.getBoolean(configKeys.AUTOLOOT) then
		local current = player:getFeature(Features.AutoLoot)
		if current == nil or current == 0 then
			player:setFeature(Features.AutoLoot, 1)
		end
	end
	return true
end

loginEvent:register()

local opcodeEvent = CreatureEvent("AutoLootOpcode")

function opcodeEvent.onExtendedOpcode(player, opcode, buffer)
	if opcode ~= AUTOLOOT_OPCODE then
		return
	end
	if not configManager.getBoolean(configKeys.AUTOLOOT) then
		return
	end
	if type(buffer) ~= "string" or buffer == "" then
		return
	end
	if not buffer:find('"setAutoLoot"', 1, true) then
		return
	end

	local mode = buffer:match('"mode"%s*:%s*"(%w+)"')
	if mode == "all" then
		player:setFeature(Features.AutoLoot, 2)
	elseif mode == "on" then
		player:setFeature(Features.AutoLoot, 1)
	elseif mode == "off" then
		player:setFeature(Features.AutoLoot, 0)
	end
end

opcodeEvent:register()
