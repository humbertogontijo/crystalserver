local mType = Game.createMonsterType("Enusat the Onyx Wing")
local monster = {}

monster.description = "Enusat the Onyx Wing"
monster.experience = 21500
monster.outfit = {
	lookType = 1189,
	lookHead = 95,
	lookBody = 114,
	lookLegs = 94,
	lookFeet = 76,
	lookAddons = 1,
	lookMount = 0,
}

monster.bosstiary = {
	bossRaceId = 2106,
	bossRace = RARITY_BANE,
}

monster.health = 25000
monster.maxHealth = 25000
monster.race = "blood"
monster.corpse = 31390
monster.speed = 150
monster.manaCost = 0

monster.changeTarget = {
	interval = 4000,
	chance = 10,
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

monster.loot = {
	{ name = "crystal coin", chance = 49254 },
	{ name = "dagger", chance = 25373 },
	{ name = "manticore ear", chance = 13433 },
	{ name = "terra boots", chance = 13433 },
	{ name = "terra rod", chance = 11940 },
	{ name = "violet gem", chance = 11940 },
	{ name = "guardian halberd", chance = 7463 },
	{ name = "manticore tail", chance = 7463 },
	{ name = "small diamond", chance = 7463 },
	{ name = "springsprout rod", chance = 7463 },
	{ name = "gold ingot", chance = 5970 },
	{ name = "sacred tree amulet", chance = 5970 },
	{ name = "small emerald", chance = 5970 },
	{ name = "fire sword", chance = 4478 },
	{ name = "knight armor", chance = 4478 },
	{ name = "onyx chip", chance = 4478 },
	{ name = "lightning headband", chance = 2985 },
	{ name = "wand of inferno", chance = 2985 },
	{ name = "lightning legs", chance = 1493 },
	{ id = 23533, chance = 1493 }, -- ring of red plasma
	{ name = "rusted armor", chance = 1493 },
	{ name = "terra hood", chance = 1493 },
	{ name = "titan axe", chance = 1493 },
}

monster.attacks = {
	{ name = "melee", interval = 2000, chance = 100, minDamage = 0, maxDamage = -650 },
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
	{ type = "invisible", condition = true },
	{ type = "bleed", condition = false },
}

mType:register(monster)
