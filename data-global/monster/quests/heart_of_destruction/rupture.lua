local mType = Game.createMonsterType("Rupture")
local monster = {}

monster.description = "Rupture"
monster.experience = 112000
monster.outfit = {
	lookType = 875,
	lookHead = 77,
	lookBody = 79,
	lookLegs = 3,
	lookFeet = 85,
	lookAddons = 0,
	lookMount = 0,
}

monster.bosstiary = {
	bossRaceId = 1225,
	bossRace = RARITY_ARCHFOE,
}

monster.health = 290000
monster.maxHealth = 290000
monster.race = "venom"
monster.corpse = 23564
monster.speed = 225
monster.manaCost = 0

monster.changeTarget = {
	interval = 2000,
	chance = 25,
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

monster.events = {
	"RuptureResonance",
	"RuptureHeal",
	"HeartBossDeath",
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
	{ id = 3031, chance = 100000, maxCount = 200 }, -- gold coin
	{ id = 3035, chance = 100000, maxCount = 10 }, -- platinum coin
	{ id = 7643, chance = 56757, maxCount = 5 }, -- ultimate health potion
	{ id = 16119, chance = 72973, maxCount = 3 }, -- blue crystal shard
	{ id = 16121, chance = 78378, maxCount = 3 }, -- green crystal shard
	{ id = 3033, chance = 18919, maxCount = 10 }, -- small amethyst
	{ id = 3029, chance = 24324, maxCount = 5 }, -- small sapphire
	{ id = 16120, chance = 70270, maxCount = 3 }, -- violet crystal shard
	{ id = 23535, chance = 100000, maxCount = 5 }, -- energy bar
	{ id = 23506, chance = 100000 }, -- plasma pearls
	{ id = 23510, chance = 100000 }, -- odd organ
	{ id = 22721, chance = 100000, maxCount = 4 }, -- gold token
	{ id = 23509, chance = 100000 }, -- mysterious remains
	{ id = 3038, chance = 16216 }, -- green gem
	{ id = 7427, chance = 16216 }, -- chaos mace
	{ id = 23531, chance = 18919 }, -- ring of green plasma
	{ id = 23533, chance = 16216 }, -- ring of red plasma
	{ id = 23474, chance = 2000, unique = true }, -- tiara of power
	{ id = 23477, chance = 13514, unique = true }, -- void boots
	{ name = "great mana potion", chance = 64865, maxCount = 15 },
	{ name = "great spirit potion", chance = 43243, maxCount = 10 },
	{ name = "yellow gem", chance = 27027 },
	{ name = "small emerald", chance = 21622, maxCount = 15 },
	{ name = "small topaz", chance = 21622, maxCount = 18 },
	{ name = "blue gem", chance = 18919 },
	{ id = 23526, chance = 18919 }, -- collar of blue plasma
	{ id = 3039, chance = 18919 }, -- red gem
	{ id = 281, chance = 16216 }, -- giant shimmering pearl
	{ name = "amber staff", chance = 13514 },
	{ name = "small diamond", chance = 13514, maxCount = 16 },
	{ id = 23527, chance = 10811 }, -- collar of green plasma
	{ id = 23529, chance = 10811 }, -- ring of blue plasma
	{ id = 23528, chance = 5405 }, -- collar of red plasma
}

monster.attacks = {
	{ name = "melee", interval = 2000, chance = 100, minDamage = -250, maxDamage = -1000 },
	{ name = "combat", interval = 2000, chance = 25, type = COMBAT_ENERGYDAMAGE, minDamage = -350, maxDamage = -800, length = 10, spread = 0, effect = CONST_ME_LOSEENERGY, target = false },
	{ name = "combat", interval = 2000, chance = 25, type = COMBAT_DEATHDAMAGE, minDamage = -150, maxDamage = -300, radius = 4, shootEffect = CONST_ANI_SUDDENDEATH, effect = CONST_ME_SMALLCLOUDS, target = true },
	{ name = "rupture wave", interval = 2000, chance = 20, minDamage = -700, maxDamage = -1100, target = false },
	{ name = "combat", interval = 2000, chance = 25, type = COMBAT_LIFEDRAIN, minDamage = -300, maxDamage = -600, length = 9, spread = 0, effect = CONST_ME_MAGIC_RED, target = false },
	{ name = "anomaly break", interval = 2000, chance = 40, target = false },
}

monster.defenses = {
	defense = 100,
	armor = 0,
	--	mitigation = ???,
	{ name = "combat", interval = 2000, chance = 15, type = COMBAT_HEALING, minDamage = 150, maxDamage = 400, effect = CONST_ME_MAGIC_BLUE, target = false },
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
	{ type = "paralyze", condition = true },
	{ type = "outfit", condition = false },
	{ type = "invisible", condition = true },
	{ type = "bleed", condition = false },
}

mType:register(monster)
