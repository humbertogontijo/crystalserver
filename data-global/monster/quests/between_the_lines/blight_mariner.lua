local mType = Game.createMonsterType("Blight Mariner")
local monster = {}

monster.description = "blight mariner"
monster.experience = 25500
monster.outfit = {
	lookType = 1221,
	lookHead = 57,
	lookBody = 9,
	lookLegs = 90,
	lookFeet = 57,
	lookAddons = 3,
	lookMount = 0,
}

monster.bosstiary = {
	bossRaceId = 2682,
	bossRace = RARITY_ARCHFOE,
}

monster.events = {
	--"BlightMarinerMonsterDeath", -- EVENT TO REGISTER THE BOSS DEATH FOR BETWEEN THE LINES QUEST
}

monster.health = 20500
monster.maxHealth = 20500
monster.race = "undead"
monster.corpse = 28601
monster.speed = 85
monster.manaCost = 0

monster.changeTarget = {
	interval = 4000,
	chance = 10,
}

monster.strategiesTarget = {
	nearest = 70,
	health = 10,
	damage = 10,
	random = 10,
}

monster.flags = {
	summonable = false,
	attackable = true,
	hostile = true,
	convinceable = false,
	pushable = false,
	rewardBoss = false,
	illusionable = false,
	canPushItems = true,
	canPushCreatures = true,
	staticAttackChance = 90,
	targetDistance = 1,
	runHealth = 0,
	healthHidden = false,
	isBlockable = false,
	canWalkOnEnergy = false,
	canWalkOnFire = false,
	canWalkOnPoison = false,
}

monster.light = {
	level = 2,
	color = 132,
}

monster.voices = {
	interval = 5000,
	chance = 10,
}

monster.loot = {
	{ name = "platinum coin", chance = 100000, maxCount = 63 },
	{ name = "black pearl", chance = 35241 },
	{ name = "white pearl", chance = 36747 },
	{ name = "onyx chip", chance = 26205, maxCount = 2 },
	{ id = 3050, chance = 28012 }, -- power ring
	{ id = 3091, chance = 32229 }, -- sword ring
	{ name = "proficiency catalyst", chance = 6928 },
	{ name = "crystalline armor", chance = 5723 },
	{ name = "two handed sword", chance = 20482 },
	{ id = 6299, chance = 27410 }, -- death ring
	{ name = "moonstone", chance = 16265 },
	{ name = "terra legs", chance = 8133 },
	{ name = "terra boots", chance = 16265 },
	{ name = "small topaz", chance = 28614, maxCount = 5 },
	{ name = "strange helmet", chance = 18373 },
	{ name = "cyan crystal fragment", chance = 24699 },
	{ name = "dark armor", chance = 18072 },
	{ name = "gold ingot", chance = 13554, maxCount = 2 },
	{ name = "mercenary sword", chance = 6928 },
	{ name = "etcher", chance = 5723 },
	{ name = "stone skin amulet", chance = 5723 },
}

-- missing spells
monster.attacks = {
	{ name = "melee", interval = 2000, chance = 100, minDamage = -50, maxDamage = -250 },
	{ name = "combat", interval = 2000, chance = 15, type = COMBAT_ICEDAMAGE, minDamage = -100, maxDamage = -350, range = 5, radius = 2, shootEffect = CONST_ANI_ICE, effect = CONST_ME_ICETORNADO, target = true },
	{ name = "combat", interval = 2000, chance = 10, type = COMBAT_HOLYDAMAGE, minDamage = -100, maxDamage = -250, range = 7, shootEffect = CONST_ANI_DEATH, effect = CONST_ME_MORTAREA, target = true },
}

monster.defenses = {
	defense = 25,
	armor = 15,
	{ name = "combat", interval = 2000, chance = 15, type = COMBAT_HEALING, minDamage = 40, maxDamage = 80, effect = CONST_ME_MAGIC_BLUE, target = false },
}

monster.elements = {
	{ type = COMBAT_PHYSICALDAMAGE, percent = 0 },
	{ type = COMBAT_ENERGYDAMAGE, percent = 0 },
	{ type = COMBAT_EARTHDAMAGE, percent = 0 },
	{ type = COMBAT_FIREDAMAGE, percent = 0 },
	{ type = COMBAT_LIFEDRAIN, percent = 0 },
	{ type = COMBAT_MANADRAIN, percent = 0 },
	{ type = COMBAT_DROWNDAMAGE, percent = 0 },
	{ type = COMBAT_ICEDAMAGE, percent = 0 },
	{ type = COMBAT_HOLYDAMAGE, percent = 0 },
	{ type = COMBAT_DEATHDAMAGE, percent = 0 },
}

monster.immunities = {
	{ type = "paralyze", condition = false },
	{ type = "outfit", condition = false },
	{ type = "invisible", condition = false },
	{ type = "bleed", condition = false },
}

mType:register(monster)
