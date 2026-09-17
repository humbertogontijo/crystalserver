local mType = Game.createMonsterType("Wrathful Archivist")
local monster = {}

monster.description = "wrathful archivist"
monster.experience = 24000
monster.outfit = {
	lookType = 194,
	lookHead = 90,
	lookBody = 116,
	lookLegs = 90,
	lookFeet = 57,
	lookAddons = 3,
	lookMount = 0,
}

monster.bosstiary = {
	bossRaceId = 2681,
	bossRace = RARITY_ARCHFOE,
}

monster.health = 15000
monster.maxHealth = 15000
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
	{ text = "THIS KNOWLEDGE IS FORBIDDEN", yell = false },
	{ text = "YOU HAVE FAILED, MORTAL!", yell = false },
	{ text = "CRUEL MORTAL!", yell = false },
	{ text = "WHAT! KEEP YOUR HANDS OFF THIS, MORTAL!", yell = false },
	{ text = "How many times do I have to repeat, THIS IS A LIBRARY!", yell = false },
	{ text = "READ AND COMPREHEND MORTAL", yell = false },
	{ text = "THEY ARE BOUND TO ME, HOW DARE YOU", yell = false },
	{ text = "Everything you do will only make me stronger", yell = false },
}

monster.loot = {
	{ name = "gold coin", chance = 37647, maxCount = 2 },
	{ name = "platinum coin", chance = 100000, maxCount = 66 },
	{ name = "mana potion", chance = 32353, maxCount = 14 },
	{ name = "violet crystal shard", chance = 20882, maxCount = 2 },
	{ name = "blue crystal splinter", chance = 19118 },
	{ id = 238, chance = 27941, maxCount = 6 }, -- great mana potion
	{ name = "strong mana potion", chance = 28824, maxCount = 14 },
	{ name = "small ruby", chance = 18824, maxCount = 3 },
	{ name = "small sapphire", chance = 18824, maxCount = 3 },
	{ name = "small emerald", chance = 20882, maxCount = 3 },
	{ name = "small amethyst", chance = 17941, maxCount = 3 },
	{ name = "spellweaver's robe", chance = 6176 },
	{ name = "proficiency catalyst", chance = 8235 },
	{ name = "blank imbuement scroll", chance = 7647 },
	{ id = 3041, chance = 37941 }, -- blue gem
	{ id = 6299, chance = 35882, maxCount = 2 }, -- death ring
	{ id = 3053, chance = 34706, maxCount = 2 }, -- time ring
	{ id = 3052, chance = 32647, maxCount = 2 }, -- life ring
	{ name = "violet gem", chance = 19412, maxCount = 2 },
	{ name = "blue crystal shard", chance = 15882, maxCount = 2 },
	{ name = "ultimate mana potion", chance = 10882 },
	{ name = "wand of inferno", chance = 7059, maxCount = 2 },
	{ name = "spellbook of mind control", chance = 5588 },
	{ name = "wand of cosmic energy", chance = 5294, maxCount = 2 },
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
