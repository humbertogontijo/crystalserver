local mType = Game.createMonsterType("Swan Maiden")
local monster = {}

monster.description = "a swan maiden"
monster.experience = 700
monster.outfit = {
	lookType = 138,
	lookHead = 0,
	lookBody = 0,
	lookLegs = 114,
	lookFeet = 78,
	lookAddons = 0,
	lookMount = 0,
}

monster.raceId = 1437
monster.Bestiary = {
	class = "Fey",
	race = BESTY_RACE_FEY,
	toKill = 1000,
	FirstUnlock = 50,
	SecondUnlock = 500,
	CharmsPoints = 25,
	Stars = 3,
	Occurrence = 1,
	Locations = "Feyrist Meadows",
}

monster.health = 800
monster.maxHealth = 800
monster.race = "blood"
monster.corpse = 25831
monster.speed = 117
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
	canPushCreatures = false,
	staticAttackChance = 90,
	targetDistance = 4,
	runHealth = 20,
	healthHidden = false,
	isBlockable = false,
	canWalkOnEnergy = false,
	canWalkOnFire = false,
	canWalkOnPoison = false,
}

monster.light = {
	level = 0,
	color = 0,
}

monster.voices = {
	interval = 5000,
	chance = 10,
	{ text = "Nightmarish monster! This dream is not meant for you!", yell = false },
	{ text = "You won't steal my robe! Back off!", yell = false },
	{ text = "You are not allowed to lay eyes on me in this shape!", yell = false },
	{ text = "Are you stalking me? You will bitterly regret this!", yell = false },
}

monster.loot = {
	{ name = "gold coin", chance = 60145, maxCount = 112 },
	{ name = "small enchanted emerald", chance = 2619, maxCount = 2 },
	{ name = "green mushroom", chance = 1363, maxCount = 2 },
	{ name = "white pearl", chance = 2032, maxCount = 2 },
	{ name = "opal", chance = 1834, maxCount = 2 },
	{ name = "strong mana potion", chance = 834 },
	{ name = "clerical mace", chance = 950 },
	{ id = 238, chance = 3164 }, -- great mana potion
	{ name = "colourful snail shell", chance = 14582 },
	{ name = "diamond sceptre", chance = 388 },
	{ name = "coral brooch", chance = 1842 },
	{ name = "flower wreath", chance = 421 },
	{ name = "powder herb", chance = 5312 },
	{ name = "silver brooch", chance = 3400 },
	{ name = "summer dress", chance = 479 },
	{ name = "wild flowers", chance = 20150 },
	{ name = "boots of haste", chance = 843 },
	{ name = "butterfly ring", chance = 744 },
}

monster.attacks = {
	{ name = "melee", interval = 2000, chance = 100, minDamage = 0, maxDamage = -160 },
	{ name = "combat", interval = 2000, chance = 15, type = COMBAT_ENERGYDAMAGE, minDamage = -83, maxDamage = -105, range = 7, shootEffect = CONST_ANI_ENERGY, effect = CONST_ME_ENERGYHIT, target = true },
	{ name = "combat", interval = 2000, chance = 11, type = COMBAT_MANADRAIN, minDamage = -82, maxDamage = -215, range = 7, shootEffect = CONST_ANI_HOLY, effect = CONST_ME_HOLYAREA, target = true },
	{ name = "speed", interval = 2000, chance = 11, speedChange = -450, radius = 6, effect = CONST_ME_PIXIE_EXPLOSION, target = false, duration = 5000 },
}

monster.defenses = {
	defense = 54,
	armor = 54,
	mitigation = 1.18,
	{ name = "combat", interval = 2000, chance = 15, type = COMBAT_HEALING, minDamage = 85, maxDamage = 105, effect = CONST_ME_MAGIC_BLUE, target = false },
}

monster.elements = {
	{ type = COMBAT_PHYSICALDAMAGE, percent = -10 },
	{ type = COMBAT_ENERGYDAMAGE, percent = 0 },
	{ type = COMBAT_EARTHDAMAGE, percent = 30 },
	{ type = COMBAT_FIREDAMAGE, percent = -10 },
	{ type = COMBAT_LIFEDRAIN, percent = 0 },
	{ type = COMBAT_MANADRAIN, percent = 0 },
	{ type = COMBAT_DROWNDAMAGE, percent = 0 },
	{ type = COMBAT_ICEDAMAGE, percent = 0 },
	{ type = COMBAT_HOLYDAMAGE, percent = 30 },
	{ type = COMBAT_DEATHDAMAGE, percent = 50 },
}

monster.immunities = {
	{ type = "paralyze", condition = true },
	{ type = "outfit", condition = false },
	{ type = "invisible", condition = true },
	{ type = "bleed", condition = false },
}

mType:register(monster)
