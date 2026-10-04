local mType = Game.createMonsterType("Tremor Worm")
local monster = {}

monster.description = "a tremor worm"
monster.experience = 80000
monster.outfit = {
	lookType = 295,
	lookHead = 0,
	lookBody = 0,
	lookLegs = 0,
	lookFeet = 0,
	lookAddons = 0,
	lookMount = 0,
}

monster.health = 125000
monster.maxHealth = 125000
monster.race = "blood"
monster.corpse = 0
monster.speed = 85
monster.manaCost = 0

monster.changeTarget = {
	interval = 2000,
	chance = 0,
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
	level = 0,
	color = 0,
}

monster.voices = {
	interval = 5000,
	chance = 10,
}

monster.loot = {
	{ id = 3035, chance = 100000, maxCount = 5 }, -- platinum coin
	{ id = 239, chance = 100000 }, -- great health potion
	{ id = 238, chance = 100000 }, -- great mana potion
	{ name = "ultimate health potion", chance = 100000, maxCount = 16 },
	{ name = "glooth bag", chance = 85714, maxCount = 3 },
	{ name = "gold coin", chance = 71429, maxCount = 153 },
	{ name = "cyan crystal fragment", chance = 57143 },
	{ name = "green crystal fragment", chance = 42857 },
	{ name = "red crystal fragment", chance = 28571 },
	{ id = 3098, chance = 28571 }, -- ring of healing
	{ name = "small diamond", chance = 28571, maxCount = 8 },
	{ name = "yellow gem", chance = 28571 },
	{ name = "glooth cape", chance = 14286 },
	{ name = "glooth glider crank", chance = 14286 },
	{ id = 3039, chance = 14286 }, -- red gem
	{ name = "small ruby", chance = 14286 },
	{ name = "stone skin amulet", chance = 14286 },
	{ id = 3053, chance = 14286 }, -- time ring
	{ name = "violet crystal shard", chance = 14286, maxCount = 3 },
}

monster.attacks = {
	{ name = "melee", interval = 2000, chance = 100, minDamage = -0, maxDamage = -400 },
}

monster.defenses = {
	defense = 100,
	armor = 100,
	--	mitigation = ???,
}

monster.elements = {
	{ type = COMBAT_PHYSICALDAMAGE, percent = 75 },
	{ type = COMBAT_ENERGYDAMAGE, percent = 75 },
	{ type = COMBAT_EARTHDAMAGE, percent = 75 },
	{ type = COMBAT_FIREDAMAGE, percent = 75 },
	{ type = COMBAT_LIFEDRAIN, percent = 75 },
	{ type = COMBAT_MANADRAIN, percent = 75 },
	{ type = COMBAT_DROWNDAMAGE, percent = 75 },
	{ type = COMBAT_ICEDAMAGE, percent = 75 },
	{ type = COMBAT_HOLYDAMAGE, percent = 75 },
	{ type = COMBAT_DEATHDAMAGE, percent = 75 },
}

monster.immunities = {
	{ type = "paralyze", condition = true },
	{ type = "outfit", condition = false },
	{ type = "invisible", condition = true },
	{ type = "bleed", condition = false },
}

mType:register(monster)
