-- Rotten Blood taints (5-9) override the heart drop chance.
local HEART_DROP_BY_TAINTS = { [5] = 0.05, [6] = 0.10, [7] = 0.15, [8] = 0.20, [9] = 0.35 }
local ROTTEN_BLOOD_HEART_BY_MONSTER = {
	["sopping corpus"] = 43854,
	["oozing corpus"] = 43854,
	["mycobiontic beetle"] = 43854,
	["bloated man-maggot"] = 43854,
	["oozing carcass"] = 43854,
	["sopping carcass"] = 43854,
	["rotten man-maggot"] = 43854,
	["meandering mushroom"] = 43854,
	["walking pillar"] = 43855,
	["darklight matter"] = 43855,
	["darklight source"] = 43855,
	["darklight striker"] = 43855,
	["darklight emitter"] = 43855,
	["darklight construct"] = 43855,
	["wandering pillar"] = 43855,
	["converter"] = 43855,
}

local GOLD_COIN_ITEM_IDS = {
	[ITEM_GOLD_COIN] = true,
	[ITEM_PLATINUM_COIN] = true,
	[ITEM_CRYSTAL_COIN] = true,
}

-- The fractional part rolls as a chance for one extra coin so e.g. 1.5x averages
-- out over many kills.
local function scaleGoldCoinCount(count)
	local scaled = count * configManager.getFloat(configKeys.RATE_GOLD_LOOT)
	local whole = math.floor(scaled)
	if math.random() < scaled - whole then
		whole = whole + 1
	end
	return whole
end

-- return a dictionary of itemId => { count, gut }
---@param config { factor: number, gut: boolean, filter?: fun(itemType: ItemType, unique: boolean): boolean }
---@return LootItems
function MonsterType:generateLootRoll(config, resultTable, player)
	if configManager.getFloat(configKeys.RATE_LOOT) <= 0 then
		return resultTable or {}
	end

	local monsterLoot = self:getLoot() or {}
	local uniqueItems = {}

	local factor = config.factor or 1.0
	if self:isRewardBoss() then
		factor = factor * SCHEDULE_BOSS_LOOT_RATE / 100
	end

	local heartItemId = ROTTEN_BLOOD_HEART_BY_MONSTER[self:getName():lower()]
	local heartChance = nil
	if heartItemId and player then
		local taints = player:kv():scoped("rotten-blood-quest"):get("taints") or 0
		local bonus = HEART_DROP_BY_TAINTS[taints]
		if bonus then
			heartChance = bonus * 1000
		end
	end

	local result = resultTable or {}
	for _, item in ipairs(monsterLoot) do
		local iType = ItemType(item.itemId)

		if config.filter and not config.filter(iType, item.unique) then
			goto continue
		end

		if uniqueItems[item.itemId] then
			goto continue
		end

		if not result[item.itemId] then
			result[item.itemId] = { count = 0, gut = false }
		end

		local chance = item.chance
		if SoulWarQuest and iType:getId() == SoulWarQuest.bagYouDesireItemId then
			result[item.itemId].chance = self:calculateBagYouDesireChance(player, chance)
			logger.debug("Final chance for bag you desire: {}, original chance: {}", result[item.itemId].chance, chance)
		end

		if heartChance and item.itemId == heartItemId then
			chance = heartChance
		end

		local dynamicFactor = factor * (math.random(95, 105) / 100)
		local adjustedChance = chance * dynamicFactor

		if iType:getType() == ITEM_TYPE_CREATUREPRODUCT then
			adjustedChance = adjustedChance * configManager.getFloat(configKeys.RATE_GOLD_LOOT)
		end

		local originalChance = chance
		if config.gut and iType:getType() == ITEM_TYPE_CREATUREPRODUCT then
			local charmChance = player:getCharmChance(CHARM_GUT)
			adjustedChance = adjustedChance + math.ceil((adjustedChance * charmChance / 100))
		end

		local randValue = getLootRandom()
		if randValue >= adjustedChance then
			goto continue
		end

		local count = 0
		local charges = iType:getCharges()
		if charges > 0 then
			count = charges
		elseif iType:isStackable() then
			local maxc, minc = item.maxCount or 1, item.minCount or 1
			count = math.max(0, randValue % (maxc - minc + 1)) + minc
		else
			count = 1
		end

		if GOLD_COIN_ITEM_IDS[item.itemId] then
			count = scaleGoldCoinCount(count)
		end

		local gutTriggered = randValue < chance and randValue > originalChance

		result[item.itemId].count = result[item.itemId].count + count
		result[item.itemId].gut = config.gut and iType:getType() == ITEM_TYPE_CREATUREPRODUCT and gutTriggered
		result[item.itemId].unique = item.unique
		result[item.itemId].subType = item.subType
		result[item.itemId].text = item.text
		result[item.itemId].actionId = item.actionId

		if count > 0 and item.unique then
			uniqueItems[item.itemId] = true
		end

		::continue::
	end

	for itemId, item in pairs(result) do
		if item.count <= 0 then
			result[itemId] = nil
		end
	end

	return result
end
