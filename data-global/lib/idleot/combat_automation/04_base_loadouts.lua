-- Starter combat-automation loadouts at vocation change (level 8).
-- Slot indices match OTClient: 1 stance, 2 ammo/cripple, 3-6 attack, 7-10 healing, 11-14 support.
-- Only items a level-8 player can use; empty stance/support until later spells unlock.

CombatAutomationConfig.BASE_LOADOUT_LEVEL = 8

local SMALL_HEALTH_POTION = 7876 -- free via NpcBuyPriceByTypeId
local MANA_POTION = 268
local ARROW = 3447

local function spellSlot(index, spellId, extra)
	local slot = {
		group = index,
		enabled = true,
		kind = "spell",
		spellId = spellId,
		triggerStat = "always",
		triggerPercent = 100,
		monsterCount = 1,
		monsterCountMode = "minimum",
	}
	if type(extra) == "table" then
		for k, v in pairs(extra) do
			slot[k] = v
		end
	end
	return slot
end

local function potionSlot(index, typeId, triggerStat, percent)
	return {
		group = index,
		enabled = true,
		kind = "potion",
		potionTypeId = typeId,
		triggerStat = triggerStat,
		triggerPercent = percent,
	}
end

local function ammoSlot(index, typeId)
	return {
		group = index,
		enabled = true,
		kind = "ammo",
		ammoTypeId = typeId,
		triggerStat = "always",
		triggerPercent = 100,
	}
end

local healHp = { triggerStat = "hp", triggerPercent = 80 }
local waveExtra = { monsterCount = 2, monsterCountMode = "minimum" }

CombatAutomationConfig.BaseLoadoutByVocation = {
	knight = {
		slots = {
			spellSlot(3, "exori_infir_min"), -- Lesser Front Sweep
			spellSlot(7, "exura_ico", healHp), -- Wound Cleansing
			potionSlot(8, SMALL_HEALTH_POTION, "hp", 50),
			potionSlot(9, MANA_POTION, "mana", 30),
		},
	},
	paladin = {
		ammoTypeId = ARROW,
		slots = {
			ammoSlot(2, ARROW),
			spellSlot(3, "exori_infir_con"), -- Lesser Ethereal Spear
			spellSlot(7, "exura", healHp), -- Light Healing
			potionSlot(8, SMALL_HEALTH_POTION, "hp", 50),
			potionSlot(9, MANA_POTION, "mana", 40),
		},
	},
	sorcerer = {
		slots = {
			spellSlot(3, "exori_min_flam"), -- Apprentice's Strike
			spellSlot(4, "exevo_infir_flam_hur", waveExtra), -- Scorch
			spellSlot(7, "exura", healHp),
			potionSlot(8, MANA_POTION, "mana", 50),
			potionSlot(9, SMALL_HEALTH_POTION, "hp", 40),
		},
	},
	druid = {
		slots = {
			spellSlot(3, "exori_min_flam"), -- Apprentice's Strike
			spellSlot(4, "exevo_infir_frigo_hur", waveExtra), -- Chill Out
			spellSlot(7, "exura", healHp),
			potionSlot(8, MANA_POTION, "mana", 50),
			potionSlot(9, SMALL_HEALTH_POTION, "hp", 40),
		},
	},
	monk = {
		slots = {
			spellSlot(3, "exori_infir_pug"), -- Swift Jab
			spellSlot(4, "exori_infir_nia"), -- Lesser Tiger Clash
			spellSlot(7, "exura", healHp),
			potionSlot(8, SMALL_HEALTH_POTION, "hp", 50),
			potionSlot(9, MANA_POTION, "mana", 30),
		},
	},
}
