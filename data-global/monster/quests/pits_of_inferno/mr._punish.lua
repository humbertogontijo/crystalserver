local mType = Game.createMonsterType("Mr. Punish")
local monster = {}

monster.description = "Mr. Punish"
monster.experience = 9000
monster.outfit = {
	lookType = 234,
	lookHead = 0,
	lookBody = 0,
	lookLegs = 0,
	lookFeet = 0,
	lookAddons = 0,
	lookMount = 0,
}

monster.bosstiary = {
	bossRaceId = 303,
	bossRace = RARITY_NEMESIS,
}

monster.health = 22000
monster.maxHealth = 22000
monster.race = "undead"
monster.corpse = 6330
monster.speed = 235
monster.manaCost = 0

monster.changeTarget = {
	interval = 2000,
	chance = 5,
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
	rewardBoss = true,
	illusionable = false,
	canPushItems = true,
	canPushCreatures = false,
	staticAttackChance = 50,
	targetDistance = 1,
	runHealth = 2000,
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
	{ text = "I kept my axe sharp, especially for you!", yell = false },
	{ text = "Time for a little torturing practice!", yell = false },
	{ text = "Scream for me!", yell = false },
}

monster.loot = {
	{ id = 6537, chance = 100000 }, -- mr. punish's handcuffs
	{ name = "gold coin", chance = 100000, maxCount = 129 },
	{ name = "demonic essence", chance = 92857 },
	{ name = "soul orb", chance = 92857 },
	{ name = "double axe", chance = 28571 },
	{ name = "jewelled backpack", chance = 21429 },
	{ name = "assassin star", chance = 14286, maxCount = 3 },
	{ name = "cat's paw", chance = 14286 },
	{ name = "gold ingot", chance = 14286 },
	{ name = "great health potion", chance = 14286 },
	{ name = "platinum coin", chance = 14286, maxCount = 2 },
	{ id = 6491, chance = 7143 }, -- bat decoration
	{ name = "great mana potion", chance = 7143 },
	{ name = "ravager's axe", chance = 7143 },
	{ name = "small diamond", chance = 7143 },
}

monster.attacks = {
	{ name = "melee", interval = 2000, chance = 100, minDamage = 0, maxDamage = -1100 },
}

monster.defenses = {
	defense = 72,
	armor = 0,
	--	mitigation = ???,
}

monster.elements = {
	{ type = COMBAT_PHYSICALDAMAGE, percent = 0 },
	{ type = COMBAT_ENERGYDAMAGE, percent = 100 },
	{ type = COMBAT_EARTHDAMAGE, percent = 100 },
	{ type = COMBAT_FIREDAMAGE, percent = 100 },
	{ type = COMBAT_LIFEDRAIN, percent = 0 },
	{ type = COMBAT_MANADRAIN, percent = 0 },
	{ type = COMBAT_DROWNDAMAGE, percent = 0 },
	{ type = COMBAT_ICEDAMAGE, percent = 100 },
	{ type = COMBAT_HOLYDAMAGE, percent = 0 },
	{ type = COMBAT_DEATHDAMAGE, percent = -10 },
}

monster.immunities = {
	{ type = "paralyze", condition = true },
	{ type = "outfit", condition = false },
	{ type = "invisible", condition = true },
	{ type = "bleed", condition = false },
}

mType:register(monster)
