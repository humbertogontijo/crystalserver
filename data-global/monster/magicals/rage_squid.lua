local mType = Game.createMonsterType("Rage Squid")
local monster = {}

monster.description = "a rage squid"
monster.experience = 16300
monster.outfit = {
	lookType = 1059,
	lookHead = 94,
	lookBody = 78,
	lookLegs = 79,
	lookFeet = 57,
	lookAddons = 0,
	lookMount = 0,
}

monster.raceId = 1668
monster.Bestiary = {
	class = "Inkborn",
	race = BESTY_RACE_INKBORN,
	toKill = 2500,
	FirstUnlock = 100,
	SecondUnlock = 1000,
	CharmsPoints = 50,
	Stars = 4,
	Occurrence = 0,
	Locations = "Secret Library (fire section).",
}

monster.health = 17000
monster.maxHealth = 17000
monster.race = "undead"
monster.corpse = 28782
monster.speed = 215
monster.manaCost = 0

monster.changeTarget = {
	interval = 5000,
	chance = 8,
}

monster.strategiesTarget = {
	nearest = 100,
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
	canWalkOnEnergy = true,
	canWalkOnFire = true,
	canWalkOnPoison = true,
}

monster.light = {
	level = 0,
	color = 0,
}

monster.voices = {
	interval = 5000,
	chance = 10,
}

monster.loot = {
	{ id = 28570, chance = 18910 }, -- glowing rune
	{ name = "great spirit potion", chance = 18671, maxCount = 3 },
	{ name = "fire mushroom", chance = 15052, maxCount = 6 },
	{ name = "small amethyst", chance = 7470, maxCount = 5 },
	{ name = "slime heart", chance = 3000 },
	{ name = "piece of dead brain", chance = 1098 },
	{ name = "platinum coin", chance = 100000, maxCount = 6 },
	{ name = "ultimate health potion", chance = 30257, maxCount = 3 },
	{ name = "small topaz", chance = 7709, maxCount = 5 },
	{ name = "small emerald", chance = 7692, maxCount = 5 },
	{ id = 3039, chance = 2215, maxCount = 5 }, -- red gem
	{ name = "orb", chance = 2147, maxCount = 5 },
	{ name = "purple tome", chance = 1042 },
	{ id = 238, chance = 19278, maxCount = 3 }, -- great mana potion
	{ name = "demonic essence", chance = 7341 },
	{ id = 28568, chance = 10000 }, -- inkwell
	{ name = "small ruby", chance = 7376, maxCount = 5 },
	{ name = "talon", chance = 2589 },
	{ name = "might ring", chance = 1784 },
	{ name = "devil helmet", chance = 845 },
	{ name = "demonrage sword", chance = 1454 },
	{ id = 7393, chance = 390 }, -- demon trophy
	{ name = "giant sword", chance = 2205 },
	{ name = "demon shield", chance = 2079 },
	{ name = "magic plate armor", chance = 150 },
	{ name = "platinum amulet", chance = 2037 },
	{ name = "wand of everblazing", chance = 300 },
	{ name = "fire axe", chance = 6002 },
}

monster.attacks = {
	{ name = "melee", interval = 2000, chance = 100, minDamage = 0, maxDamage = -600 },
	{ name = "combat", interval = 1000, chance = 15, type = COMBAT_FIREDAMAGE, minDamage = -500, maxDamage = -700, range = 7, shootEffect = CONST_ANI_FLAMMINGARROW, effect = CONST_ME_HITBYFIRE, target = false },
	{ name = "combat", interval = 2000, chance = 10, type = COMBAT_FIREDAMAGE, minDamage = -500, maxDamage = -700, range = 7, shootEffect = CONST_ANI_FIRE, target = false },
	{ name = "combat", interval = 2000, chance = 10, type = COMBAT_LIFEDRAIN, minDamage = -175, maxDamage = -200, length = 5, spread = 0, effect = CONST_ME_MAGIC_RED, target = false },
	{ name = "combat", interval = 2000, chance = 12, type = COMBAT_FIREDAMAGE, minDamage = -100, maxDamage = -700, radius = 3, effect = CONST_ME_HITBYFIRE, target = false },
	{ name = "combat", interval = 2000, chance = 10, type = COMBAT_FIREDAMAGE, minDamage = -100, maxDamage = -700, radius = 2, effect = CONST_ME_FIREAREA, target = false },
}

monster.defenses = {
	defense = 78,
	armor = 78,
	mitigation = 2.16,
}

monster.elements = {
	{ type = COMBAT_PHYSICALDAMAGE, percent = 0 },
	{ type = COMBAT_ENERGYDAMAGE, percent = 0 },
	{ type = COMBAT_EARTHDAMAGE, percent = 0 },
	{ type = COMBAT_FIREDAMAGE, percent = 100 },
	{ type = COMBAT_LIFEDRAIN, percent = 0 },
	{ type = COMBAT_MANADRAIN, percent = 0 },
	{ type = COMBAT_DROWNDAMAGE, percent = 0 },
	{ type = COMBAT_ICEDAMAGE, percent = -15 },
	{ type = COMBAT_HOLYDAMAGE, percent = 0 },
	{ type = COMBAT_DEATHDAMAGE, percent = 0 },
}

monster.immunities = {
	{ type = "paralyze", condition = true },
	{ type = "outfit", condition = false },
	{ type = "invisible", condition = true },
	{ type = "bleed", condition = false },
}

mType:register(monster)
