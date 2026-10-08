-- Boss detail sheet for the expedition client (opcode 113), separate from bestiary.
-- Builds a payload shaped like OTC BestiaryMonsterData so fillBestiaryCreatureInfo works.

ExpeditionBossDetail = ExpeditionBossDetail or {}

-- Crystal IOBosstiary::levelInfos (prowess / expertise / mastery kills).
local BOSS_KILL_STAGES = {
	Bane = { 25, 100, 300 },
	Archfoe = { 5, 20, 60 },
	Nemesis = { 1, 3, 5 },
}

local BOSS_STARS = {
	Bane = 2,
	Archfoe = 3,
	Nemesis = 5,
}

local function lootDifficulty(chance)
	local chanceInPercent = (tonumber(chance) or 0) / 1000
	if chanceInPercent < 0.2 then
		return 4
	elseif chanceInPercent < 1 then
		return 3
	elseif chanceInPercent < 5 then
		return 2
	elseif chanceInPercent < 25 then
		return 1
	end
	return 0
end

local function resolveMonsterType(creatureId, nameHint)
	local name = ExpeditionConfig.monsterNameByCreatureId(creatureId, nameHint)
	if not name then
		return nil, nil
	end
	local mType = MonsterType(name)
	if not mType then
		return nil, name
	end
	return mType, name
end

local function bosstiaryClassName(mType, fallback)
	local className = mType:bossRace()
	if type(className) == "string" and className ~= "" then
		return className
	end
	if type(fallback) == "string" and fallback ~= "" then
		return fallback
	end
	return "Archfoe"
end

local function buildCombat(mType)
	-- 1-indexed percent taken (100 = neutral), matching OTC BestiaryMonsterData push.
	local combat = { 100, 100, 100, 100, 100, 100, 100, 100 }
	local elements = mType:getElementList()
	if type(elements) ~= "table" then
		return combat
	end
	local indexByType = {
		[COMBAT_PHYSICALDAMAGE] = 1,
		[COMBAT_FIREDAMAGE] = 2,
		[COMBAT_EARTHDAMAGE] = 3,
		[COMBAT_ENERGYDAMAGE] = 4,
		[COMBAT_ICEDAMAGE] = 5,
		[COMBAT_HOLYDAMAGE] = 6,
		[COMBAT_DEATHDAMAGE] = 7,
		[COMBAT_HEALING] = 8,
	}
	for combatType, absorb in pairs(elements) do
		local idx = indexByType[combatType]
		if idx then
			combat[idx] = 100 - (tonumber(absorb) or 0)
		end
	end
	return combat
end

local function buildLoot(mType)
	local out = {}
	local lootList = mType:getLoot()
	if type(lootList) ~= "table" then
		return out
	end
	for _, block in ipairs(lootList) do
		local itemId = block and tonumber(block.itemId) or 0
		if itemId > 0 then
			local name = ItemType(itemId):getName()
			local maxCount = tonumber(block.maxCount) or 0
			out[#out + 1] = {
				itemId = itemId,
				diffculty = lootDifficulty(block.chance),
				specialEvent = 0,
				name = name,
				amount = maxCount > 0 and 1 or 0,
				stackable = maxCount > 0 and 1 or 0,
			}
		end
	end
	return out
end

--- Payload compatible with Cyclopedia.fillBestiaryCreatureInfo.
function ExpeditionBossDetail.build(player, creatureId, nameHint, bosstiaryClassHint)
	creatureId = tonumber(creatureId)
	if not creatureId or creatureId <= 0 then
		return nil, "Invalid boss id."
	end

	local mType, resolvedName = resolveMonsterType(creatureId, nameHint)
	if not mType then
		return nil, string.format("Unknown boss (%s).", tostring(nameHint or creatureId))
	end

	local className = bosstiaryClassName(mType, bosstiaryClassHint)
	local stages = BOSS_KILL_STAGES[className] or BOSS_KILL_STAGES.Archfoe
	local stars = BOSS_STARS[className] or 3

	local killCounter = 0
	if player then
		killCounter = tonumber(player:getBosstiaryKills(resolvedName)) or 0
	end

	local attackMode = 0
	if not mType:isHostile() then
		attackMode = 2
	elseif (tonumber(mType:targetDistance()) or 1) > 1 then
		attackMode = 1
	end

	local charmValue = 0
	if mType.BestiaryCharmsPoints then
		charmValue = tonumber(mType:BestiaryCharmsPoints()) or 0
	end

	local location = ""
	if mType.BestiaryLocations then
		location = mType:BestiaryLocations() or ""
	end
	if location == "" then
		location = "Expedition"
	end

	return {
		id = creatureId,
		class = className,
		currentLevel = 4,
		AnimusMasteryPoints = 0,
		AnimusMasteryBonus = 0,
		killCounter = killCounter,
		-- Progress goals (must be > 0 - client divides by these).
		thirdDifficulty = stages[1],
		secondUnlock = stages[2],
		lastProgressKillCount = stages[3],
		difficulty = stars,
		ocorrence = 0,
		loot = buildLoot(mType),
		charmValue = charmValue,
		attackMode = attackMode,
		maxHealth = tonumber(mType:maxHealth()) or 0,
		experience = tonumber(mType:experience()) or 0,
		speed = tonumber(mType:baseSpeed()) or 0,
		armor = tonumber(mType:armor()) or 0,
		mitigation = tonumber(mType:mitigation()) or 0,
		combat = buildCombat(mType),
		location = location,
	}
end
