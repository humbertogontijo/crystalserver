local mType = Game.createMonsterType("The Blazing Rose")
local monster = {}

monster.description = "The Blazing Rose"
monster.experience = 10000
monster.outfit = {
	lookType = 1068,
	lookHead = 114,
	lookBody = 113,
	lookLegs = 76,
	lookFeet = 79,
	lookAddons = 3,
	lookMount = 0,
}

monster.bosstiary = {
	bossRaceId = 1600,
	bossRace = RARITY_ARCHFOE,
}

monster.health = 10000
monster.maxHealth = 10000
monster.race = "undead"
monster.corpse = 28794
monster.speed = 175
monster.manaCost = 0

monster.events = {
	"AsurasMechanic",
}

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
	rewardBoss = true,
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
	{ name = "gold coin", chance = 100000, maxCount = 378 },
	{ name = "golden lotus brooch", chance = 100000 },
	{ name = "peacock feather fan", chance = 100000 },
	{ name = "perfume flacon", chance = 100000 },
	{ name = "platinum coin", chance = 100000, maxCount = 10 },
	{ name = "assassin star", chance = 54032, maxCount = 15 },
	{ name = "flask of demonic blood", chance = 39516 },
	{ name = "demonic essence", chance = 30645 },
	{ name = "small amethyst", chance = 25806, maxCount = 3 },
	{ name = "soul orb", chance = 24194 },
	{ name = "great mana potion", chance = 16129, maxCount = 5 },
	{ name = "great spirit potion", chance = 14516, maxCount = 5 },
	{ id = 3039, chance = 14516 }, -- red gem
	{ name = "moonlight rod", chance = 11290 },
	{ name = "ultimate health potion", chance = 11290, maxCount = 5 },
	{ id = 3007, chance = 8065 }, -- crystal ring
	{ name = "gold ingot", chance = 6452, maxCount = 3 },
	{ name = "underworld rod", chance = 5645 },
}

monster.attacks = {
	{ name = "melee", interval = 2000, chance = 100, minDamage = 0, maxDamage = -200 },
	{ name = "combat", interval = 1000, chance = 15, type = COMBAT_PHYSICALDAMAGE, minDamage = 0, maxDamage = -180, range = 7, shootEffect = CONST_ANI_SNOWBALL, effect = CONST_ME_POFF, target = false },
	{ name = "combat", interval = 1000, chance = 12, type = COMBAT_ENERGYDAMAGE, minDamage = 0, maxDamage = -175, length = 3, spread = 0, effect = CONST_ME_POFF, target = false },
}

monster.defenses = {
	defense = 33,
	armor = 0,
	--	mitigation = ???,
}

monster.elements = {
	{ type = COMBAT_PHYSICALDAMAGE, percent = 0 },
	{ type = COMBAT_ENERGYDAMAGE, percent = 20 },
	{ type = COMBAT_EARTHDAMAGE, percent = 20 },
	{ type = COMBAT_FIREDAMAGE, percent = 100 },
	{ type = COMBAT_LIFEDRAIN, percent = 0 },
	{ type = COMBAT_MANADRAIN, percent = 0 },
	{ type = COMBAT_DROWNDAMAGE, percent = 0 },
	{ type = COMBAT_ICEDAMAGE, percent = 0 },
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
