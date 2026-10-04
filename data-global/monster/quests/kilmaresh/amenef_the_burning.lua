local mType = Game.createMonsterType("Amenef the Burning")
local monster = {}

monster.description = "Amenef the Burning"
monster.experience = 21500
monster.outfit = {
	lookType = 541,
	lookHead = 113,
	lookBody = 114,
	lookLegs = 113,
	lookFeet = 113,
	lookAddons = 1,
	lookMount = 0,
}

monster.bosstiary = {
	bossRaceId = 2103,
	bossRace = RARITY_ARCHFOE,
}

monster.health = 26000
monster.maxHealth = 26000
monster.race = "blood"
monster.corpse = 31646
monster.speed = 115
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
	rewardBoss = true,
	illusionable = false,
	canPushItems = true,
	canPushCreatures = true,
	staticAttackChance = 70,
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
	{ name = "crystal coin", chance = 46447, maxCount = 1 },
	{ name = "slightly rusted legs", chance = 15228 },
	{ name = "slightly rusted armor", chance = 12183 },
	{ name = "guardian halberd", chance = 11168 },
	{ id = 3097, chance = 8122 }, -- dwarven ring
	{ name = "mastermind potion", chance = 6853 },
	{ name = "doublet", chance = 7614 },
	{ name = "knight armor", chance = 7107 },
	{ id = 23529, chance = 3807 }, -- ring of blue plasma
	{ name = "epee", chance = 4061 },
	{ name = "underworld rod", chance = 4315 },
	{ name = "knight axe", chance = 4061 },
	{ name = "springsprout rod", chance = 3553 },
	{ name = "wand of cosmic energy", chance = 3046 },
	{ name = "wand of inferno", chance = 2538 },
	{ id = 281, chance = 3553 }, -- giant shimmering pearl (green)
	{ name = "spellbook of warding", chance = 2284 },
	{ name = "violet gem", chance = 2030 },
	{ name = "wand of starstorm", chance = 3553 },
	{ name = "amber staff", chance = 1269 },
	{ name = "assassin dagger", chance = 2284 },
	{ name = "blue gem", chance = 2284 },
	{ name = "eye-embroidered veil", chance = 1523 },
	{ name = "warrior's axe", chance = 1777 },
	{ name = "focus cape", chance = 1269 },
	{ name = "noble axe", chance = 1269 },
	{ name = "sacred tree amulet", chance = 3299 },
	{ name = "golden mask", chance = 1015 },
	{ name = "mercenary sword", chance = 1523 },
}

monster.attacks = {
	{ name = "melee", interval = 2000, chance = 100, minDamage = 0, maxDamage = -925 },
	{ name = "firering", interval = 2000, chance = 10, minDamage = -300, maxDamage = -600, target = false },
	{ name = "firex", interval = 2000, chance = 15, minDamage = -450, maxDamage = -750, target = false },
	{ name = "combat", interval = 2000, chance = 17, type = COMBAT_FIREDAMAGE, minDamage = -300, maxDamage = -600, radius = 2, effect = CONST_ME_FIREATTACK, target = false },
	{ name = "combat", interval = 2000, chance = 10, type = COMBAT_ENERGYDAMAGE, minDamage = -500, maxDamage = -750, length = 3, spread = 0, effect = CONST_ME_ENERGYHIT, target = false },
}

monster.defenses = {
	defense = 60,
	armor = 82,
	--	mitigation = ???,
}

monster.elements = {
	{ type = COMBAT_PHYSICALDAMAGE, percent = 0 },
	{ type = COMBAT_ENERGYDAMAGE, percent = 10 },
	{ type = COMBAT_EARTHDAMAGE, percent = 0 },
	{ type = COMBAT_FIREDAMAGE, percent = 15 },
	{ type = COMBAT_LIFEDRAIN, percent = 0 },
	{ type = COMBAT_MANADRAIN, percent = 0 },
	{ type = COMBAT_DROWNDAMAGE, percent = 0 },
	{ type = COMBAT_ICEDAMAGE, percent = -20 },
	{ type = COMBAT_HOLYDAMAGE, percent = 0 },
	{ type = COMBAT_DEATHDAMAGE, percent = 0 },
}

monster.immunities = {
	{ type = "paralyze", condition = true },
	{ type = "outfit", condition = true },
	{ type = "invisible", condition = true },
	{ type = "bleed", condition = false },
}

mType:register(monster)
