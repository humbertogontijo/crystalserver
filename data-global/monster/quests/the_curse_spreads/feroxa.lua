local mType = Game.createMonsterType("Feroxa")
local monster = {}

monster.description = "Feroxa"
monster.experience = 0
monster.outfit = {
	lookType = 158,
	lookHead = 57,
	lookBody = 76,
	lookLegs = 77,
	lookFeet = 57,
	lookAddons = 0,
	lookMount = 0,
}

monster.health = 100000
monster.maxHealth = 100000
monster.race = "blood"
monster.corpse = 0
monster.speed = 175
monster.manaCost = 0

monster.changeTarget = {
	interval = 2000,
	chance = 2,
}

monster.bosstiary = {
	bossRaceId = 1149,
	bossRace = RARITY_NEMESIS,
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
	targetDistance = 4,
	runHealth = 0,
	healthHidden = false,
	isBlockable = false,
	canWalkOnEnergy = false,
	canWalkOnFire = false,
	canWalkOnPoison = false,
}

monster.events = {
	"FeroxaTransform",
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
	{ name = "moonlight crystals", chance = 100000, maxCount = 9 },
	{ name = "platinum coin", chance = 100000, maxCount = 32 },
	{ name = "great mana potion", chance = 67797, maxCount = 10 },
	{ name = "small diamond", chance = 64407, maxCount = 5 },
	{ name = "ultimate health potion", chance = 64407, maxCount = 9 },
	{ name = "violet crystal shard", chance = 62712, maxCount = 3 },
	{ name = "small ruby", chance = 57627, maxCount = 8 },
	{ name = "great health potion", chance = 52542, maxCount = 9 },
	{ name = "red crystal fragment", chance = 52542 },
	{ name = "blue gem", chance = 45763 },
	{ id = 3039, chance = 45763 }, -- red gem
	{ id = 22099, chance = 30508 }, -- trophy of Feroxa
	{ name = "gold coin", chance = 25424, maxCount = 381 },
	{ name = "blue crystal shard", chance = 23729, maxCount = 9 },
	{ name = "blue crystal splinter", chance = 22034, maxCount = 9 },
	{ name = "brown crystal splinter", chance = 13559, maxCount = 8 },
	{ name = "great spirit potion", chance = 13559, maxCount = 8 },
	{ name = "wereboar loincloth", chance = 13559 },
	{ name = "badger boots", chance = 11864 },
	{ name = "fur armor", chance = 11864 },
	{ name = "green crystal splinter", chance = 11864, maxCount = 9 },
	{ name = "small sapphire", chance = 11864, maxCount = 9 },
	{ name = "green crystal shard", chance = 10169, maxCount = 9 },
	{ name = "small topaz", chance = 10169, maxCount = 8 },
	{ name = "wand of voodoo", chance = 10169 },
	{ name = "moonlight rod", chance = 8475 },
	{ name = "werewolf amulet", chance = 8475 },
	{ name = "dreaded cleaver", chance = 6780 },
	{ name = "small amethyst", chance = 6780, maxCount = 8 },
	{ name = "underworld rod", chance = 6780 },
	{ name = "bonebreaker", chance = 5085 },
	{ name = "werewolf helmet", chance = 5085 },
	{ name = "wolf backpack", chance = 5085 },
	{ name = "moonlight crystals", chance = 85714, maxCount = 3 },
	{ name = "platinum coin", chance = 85714, maxCount = 20 },
	{ name = "brown crystal splinter", chance = 13559, maxCount = 5 },
	{ name = "fur armor", chance = 11864 },
	{ name = "moonlight rod", chance = 8475 },
	{ name = "small diamond", chance = 64407, maxCount = 5 },
	{ name = "violet crystal shard", chance = 62712, maxCount = 5 },
	{ name = "badger boots", chance = 11864 },
	{ name = "blue crystal splinter", chance = 28571, maxCount = 5 },
	{ name = "great spirit potion", chance = 13559, maxCount = 5 },
	{ name = "green crystal shard", chance = 10169, maxCount = 5 },
	{ name = "gold coin", chance = 28571, maxCount = 200 },
	{ name = "great mana potion", chance = 67797, maxCount = 5 },
	{ name = "small sapphire", chance = 11864, maxCount = 5 },
	{ name = "ultimate health potion", chance = 64407, maxCount = 5 },
	{ name = "blue crystal shard", chance = 23729, maxCount = 5 },
	{ name = "green crystal splinter", chance = 14286, maxCount = 5 },
	{ name = "small topaz", chance = 10169, maxCount = 5 },
	{ name = "stone skin amulet", chance = 1695 },
	{ name = "underworld rod", chance = 6780 },
	{ name = "wand of voodoo", chance = 10169 },
	{ name = "wereboar loincloth", chance = 14286 },
	{ name = "werewolf amulet", chance = 8475 },
}

monster.attacks = {
	{ name = "melee", interval = 2000, chance = 100, minDamage = -1400, maxDamage = -1800 },
	{ name = "combat", interval = 2000, chance = 20, type = COMBAT_DEATHDAMAGE, minDamage = -700, maxDamage = -1250, radius = 6, effect = CONST_ME_MORTAREA, target = false },
	{ name = "combat", interval = 2000, chance = 20, type = COMBAT_MANADRAIN, minDamage = -700, maxDamage = -1250, radius = 5, effect = CONST_ME_ICETORNADO, target = true },
	{ name = "combat", interval = 2000, chance = 20, type = COMBAT_EARTHDAMAGE, minDamage = -700, maxDamage = -1250, range = 6, shootEffect = CONST_ANI_ARROW, effect = CONST_ME_EXPLOSIONAREA, target = true },
}

monster.defenses = {
	defense = 55,
	armor = 0,
	{ name = "speed", interval = 2000, chance = 12, speedChange = 1250, effect = CONST_ME_THUNDER, target = false, duration = 10000 },
	{ name = "feroxa summon", interval = 2000, chance = 20, target = false },
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
