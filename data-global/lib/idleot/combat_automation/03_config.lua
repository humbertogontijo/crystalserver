CombatAutomationConfig = CombatAutomationConfig or {}

-- Same extended opcode as expeditions (JSON multiplexed by action/type).
CombatAutomationConfig.OPCODE = 113
CombatAutomationConfig.KV_KEY = "combat_automation"

-- Automation tick: combat, movement and the cave walker (Cavebot runs, expedition AI).
CombatAutomationConfig.TICK_MS = 250
CombatAutomationConfig.POTION_EXHAUST_MS = 1000
CombatAutomationConfig.RUNE_EXHAUST_MS = 2000
CombatAutomationConfig.SPELL_EXHAUST_MS = 2000

-- Auto-target score (one system for every member; highest wins, ties nearest). The
-- anchor box is the expedition anchor's 3x3 (the player itself for the anchor / solo).
-- Area value counts extra monsters hit by the member's best target-centred (runes,
-- diamond arrows) or directional (waves) attack aimed at the candidate.
CombatAutomationConfig.TARGET_BOSS_BONUS = 100
CombatAutomationConfig.TARGET_BLOCKER_BONUS = 20
CombatAutomationConfig.TARGET_ROUTE_AHEAD_BONUS = 3
CombatAutomationConfig.TARGET_BOX_BONUS = 12
CombatAutomationConfig.TARGET_BOX_NEAR_BONUS = 4
CombatAutomationConfig.TARGET_AREA_PER_HIT = 4
CombatAutomationConfig.TARGET_AREA_CAP = 16
CombatAutomationConfig.TARGET_MELEE_ADJACENT_BONUS = 6
CombatAutomationConfig.TARGET_MELEE_NEAR_BONUS = 3
CombatAutomationConfig.TARGET_RANGED_IN_RANGE_BONUS = 3
CombatAutomationConfig.TARGET_ATTACKING_ME_BONUS = 3
CombatAutomationConfig.TARGET_FINISH_HP_PERCENT = 25
CombatAutomationConfig.TARGET_FINISH_BONUS = 5
CombatAutomationConfig.TARGET_WOUNDED_HP_PERCENT = 50
CombatAutomationConfig.TARGET_WOUNDED_BONUS = 2
-- Current-target bonus a rival must beat.
CombatAutomationConfig.TARGET_STICKY_BONUS = 2
-- Keep a live on-screen target this long after it leaves line of sight.
CombatAutomationConfig.TARGET_SIGHT_GRACE_MS = 1000

-- Stance roles: Chebyshev distance kept from the focus (close / ranged) or adjacent
-- (melee). Knights are melee-locked; monks close; paladins close or ranged; mages ranged.
CombatAutomationConfig.RANGED_DISTANCE_DEFAULT = 3

-- Cure spells fire only while the caster has the condition they dispel (matching
-- data/scripts/spells/healing/cure_*.lua COMBAT_PARAM_DISPEL), never on HP/mana.
-- Condition globals are looked up at call time (enums load after libs).
CombatAutomationConfig.CureConditionByWords = {
	["exana pox"] = "CONDITION_POISON",
	["exana flam"] = "CONDITION_FIRE",
	["exana vis"] = "CONDITION_ENERGY",
	["exana kor"] = "CONDITION_BLEEDING",
	["exana mort"] = "CONDITION_CURSED",
}

--- Condition type a cure spell removes, or nil when `words` is not a cure.
function CombatAutomationConfig.cureConditionForWords(words)
	local name = CombatAutomationConfig.CureConditionByWords[tostring(words or ""):lower()]
	local condition = name and _G[name]
	return type(condition) == "number" and condition or nil
end
CombatAutomationConfig.STANCE_DISTANCE = { melee = 1, close = 1, ranged = CombatAutomationConfig.RANGED_DISTANCE_DEFAULT }

local function vocationKey(player)
	if player then
		return CombatAutomationCatalog.baseVocationKey(player) or ""
	end
	return ""
end

--- Default stance for the player's vocation.
function CombatAutomationConfig.stanceForPlayer(player)
	local key = vocationKey(player)
	if key == "sorcerer" or key == "druid" then
		return "ranged"
	end
	if key == "paladin" or key == "monk" then
		return "close"
	end
	return "melee"
end

--- Stance roles a vocation may pick in the AUTO stance modal.
function CombatAutomationConfig.allowedStancesForPlayer(player)
	local key = vocationKey(player)
	if key == "monk" then
		return { "close" }
	end
	if key == "paladin" then
		return { "close", "ranged" }
	end
	return { CombatAutomationConfig.stanceForPlayer(player) }
end

--- Validate the stance against the vocation (else its default); returns role, rangedDistance.
function CombatAutomationConfig.normalizeStanceForPlayer(player, stance)
	local role = tostring(stance)
	for _, entry in ipairs(CombatAutomationConfig.allowedStancesForPlayer(player)) do
		if entry == role then
			return role, CombatAutomationConfig.RANGED_DISTANCE_DEFAULT
		end
	end
	return CombatAutomationConfig.stanceForPlayer(player), CombatAutomationConfig.RANGED_DISTANCE_DEFAULT
end

--- Persisted automation stance for a player (vocation-validated): role, rangedDistance.
function CombatAutomationConfig.configuredStanceForPlayer(player)
	local at = nil
	local cfg = CombatAutomationStore.getConfig(player)
	at = cfg and cfg.autoTarget
	return CombatAutomationConfig.normalizeStanceForPlayer(player, at and at.stance)
end

-- Movement (CombatAutomationMovement). Path search radius (Chebyshev) of directive
-- walks: getPathMatchingCond, without the 100-node hard stop.
CombatAutomationConfig.PATH_MAX_SEARCH = 128
-- Client walk / follow input pauses the AI's movement for that member; the AI takes
-- over again this long after the last manual step (or at once via "Resume Auto").
CombatAutomationConfig.MANUAL_CONTROL_MS = 3000
-- Companions beyond CATCH_UP_WALK_SQM walk toward the anchor (path search CATCH_UP_PATH_MAX).
-- Teleport only when on another floor, or beyond CATCH_UP_TELEPORT_SQM with no
-- progress for CATCH_UP_STALL_MS.
CombatAutomationConfig.CATCH_UP_WALK_SQM = 10
CombatAutomationConfig.CATCH_UP_PATH_MAX = 256
CombatAutomationConfig.CATCH_UP_TELEPORT_SQM = 15
CombatAutomationConfig.CATCH_UP_STALL_MS = 10000
-- Below this HP percent a member positions by creature stance (retreat), not formation.
CombatAutomationConfig.POSITION_CRITICAL_HP_PERCENT = 30

function CombatAutomationConfig.isPositionCritical(player)
	local maxHp = player:getMaxHealth()
	return maxHp > 0 and player:getHealth() * 100 < CombatAutomationConfig.POSITION_CRITICAL_HP_PERCENT * maxHp
end

--- Chebyshev distance the member's stance keeps from its focus.
function CombatAutomationConfig.stanceDistanceOf(config)
	local role = config and config.autoTarget and config.autoTarget.stance or "melee"
	return CombatAutomationConfig.STANCE_DISTANCE[role] or 1
end

CombatAutomationConfig.RuneWordsByTypeId = {
	[17512] = "adori dis min vis", -- lightest magic missile
	[21351] = "adori infir mas tera", -- light stone shower
	[21352] = "adori infir vis", -- lightest missile
	[3155] = "adori gran mort", -- sudden death
	[3158] = "adori frigo", -- icicle
	[3161] = "adori mas frigo", -- avalanche
	[3174] = "adori min vis", -- light magic missile
	[3175] = "adori mas tera", -- stone shower
	[3179] = "adori tera", -- stalagmite
	[3182] = "adori san", -- holy missile
	[3189] = "adori flam", -- fireball
	[3191] = "adori mas flam", -- great fireball
	[3195] = "adevo res flam", -- soulfire
	[3198] = "adori vis", -- heavy magic missile
	[3200] = "adevo mas hur", -- explosion
	[3202] = "adori mas vis", -- thunderstorm
}

-- Offensive (attack) runes only. Vocation lists match rune scripts; empty = any vocation may use.
CombatAutomationConfig.AllowedRunes = {
	[17512] = true,
	[21351] = true,
	[21352] = true,
	[3155] = true,
	[3158] = true,
	[3161] = true,
	[3174] = true,
	[3175] = true,
	[3179] = true,
	[3182] = true,
	[3189] = true,
	[3191] = true,
	[3195] = true,
	[3198] = true,
	[3200] = true,
	[3202] = true,
}

-- Empty vocations = any. Names match vocation:getName():lower().
CombatAutomationConfig.RuneVocationsByTypeId = {
	[17512] = {
		"sorcerer",
		"master sorcerer",
		"druid",
		"elder druid",
		"paladin",
		"royal paladin",
		"knight",
		"elite knight",
	},
	[21351] = {},
	[21352] = {
		"sorcerer",
		"master sorcerer",
		"druid",
		"elder druid",
		"paladin",
		"royal paladin",
	},
	[3155] = {},
	[3158] = {},
	[3161] = {},
	[3174] = {},
	[3175] = {},
	[3179] = {},
	[3182] = { "paladin", "royal paladin" },
	[3189] = {},
	[3191] = {},
	[3195] = {},
	[3198] = {},
	[3200] = {},
	[3202] = {},
}

CombatAutomationConfig.RuneMinLevelByTypeId = {
	[17512] = 1,
	[21351] = 1,
	[21352] = 1,
	[3155] = 45,
	[3158] = 28,
	[3161] = 30,
	[3174] = 15,
	[3175] = 28,
	[3179] = 24,
	[3182] = 27,
	[3189] = 27,
	[3191] = 30,
	[3195] = 27,
	[3198] = 25,
	[3200] = 31,
	[3202] = 28,
}

-- NPC shop buy prices (gold) charged per server-side potion/rune/ammo use.
-- Sourced from common OTBR potion/rune NPC shops (most common buy value).
-- Ammo prices match hireling distance shop. Keep in sync with OTClient catalogs.
CombatAutomationConfig.NpcBuyPriceByTypeId = {
	[266] = 50, -- health potion
	[268] = 56, -- mana potion
	[7876] = 0, -- small health potion (free for combat automation)
	[236] = 115, -- strong health potion
	[237] = 108, -- strong mana potion
	[238] = 158, -- great mana potion
	[239] = 225, -- great health potion
	[7642] = 254, -- great spirit potion
	[7643] = 379, -- ultimate health potion
	[23373] = 488, -- ultimate mana potion
	[23374] = 488, -- ultimate spirit potion
	[23375] = 650, -- supreme health potion
	[53162] = 254, -- superior mana potion
	[53163] = 381, -- distilled superior mana potion
	[53164] = 732, -- distilled ultimate mana potion
	[3155] = 162, -- sudden death rune
	[3158] = 30, -- icicle rune
	[3161] = 64, -- avalanche rune
	[3174] = 4, -- light magic missile rune
	[3175] = 41, -- stone shower rune
	[3179] = 12, -- stalagmite rune
	[3182] = 16, -- holy missile rune
	[3189] = 30, -- fireball rune
	[3191] = 64, -- great fireball rune
	[3195] = 46, -- soulfire rune
	[3198] = 12, -- heavy magic missile rune
	[3200] = 31, -- explosion rune
	[3202] = 52, -- thunderstorm rune
	[17512] = 4, -- lightest magic missile rune (fallback; uncommon in shops)
	[21351] = 5, -- light stone shower rune (fallback)
	[21352] = 4, -- lightest missile rune (fallback)
	-- Ammo (hireling distance shop)
	[3447] = 2, -- arrow
	[3446] = 4, -- bolt
	[761] = 5, -- flash arrow
	[762] = 5, -- shiver arrow
	[763] = 5, -- flaming arrow
	[774] = 5, -- earth arrow
	[7364] = 5, -- sniper arrow
	[7363] = 5, -- piercing bolt
	[7365] = 7, -- onyx arrow
	[3450] = 7, -- power bolt
	[14251] = 6, -- tarsal arrow
	[14252] = 6, -- vortex bolt
	[16143] = 12, -- envenomed arrow
	[16142] = 12, -- drill bolt
	[16141] = 20, -- prismatic bolt
	[15793] = 450, -- crystalline arrow
	[35901] = 130, -- diamond arrow
	[35902] = 70, -- spectral bolt
}

-- Paladin distance ammo selectable in combat automation.
-- kind: "arrow" (bows) or "bolt" (crossbows). minLevel from item weapon scripts.
CombatAutomationConfig.AllowedAmmo = {
	[3447] = { kind = "arrow", minLevel = 1 }, -- arrow
	[761] = { kind = "arrow", minLevel = 20 }, -- flash arrow
	[762] = { kind = "arrow", minLevel = 20 }, -- shiver arrow
	[763] = { kind = "arrow", minLevel = 20 }, -- flaming arrow
	[774] = { kind = "arrow", minLevel = 20 }, -- earth arrow
	[7364] = { kind = "arrow", minLevel = 20 }, -- sniper arrow
	[7365] = { kind = "arrow", minLevel = 40 }, -- onyx arrow
	[14251] = { kind = "arrow", minLevel = 30 }, -- tarsal arrow
	[16143] = { kind = "arrow", minLevel = 70 }, -- envenomed arrow
	[15793] = { kind = "arrow", minLevel = 90 }, -- crystalline arrow
	[35901] = { kind = "arrow", minLevel = 150 }, -- diamond arrow
	[3446] = { kind = "bolt", minLevel = 1 }, -- bolt
	[7363] = { kind = "bolt", minLevel = 30 }, -- piercing bolt
	[3450] = { kind = "bolt", minLevel = 55 }, -- power bolt
	[14252] = { kind = "bolt", minLevel = 40 }, -- vortex bolt
	[16142] = { kind = "bolt", minLevel = 70 }, -- drill bolt
	[16141] = { kind = "bolt", minLevel = 90 }, -- prismatic bolt
	[35902] = { kind = "bolt", minLevel = 150 }, -- spectral bolt
}

-- Ammo that hits an area around the target (data/scripts/weapons/scripts/*.lua),
-- as offsets from the target tile.
local DIAMOND_ARROW_AREA = {
	kind = "target",
	tiles = {
		{ -1, -2 }, { 0, -2 }, { 1, -2 },
		{ -2, -1 }, { -1, -1 }, { 0, -1 }, { 1, -1 }, { 2, -1 },
		{ -2, 0 }, { -1, 0 }, { 0, 0 }, { 1, 0 }, { 2, 0 },
		{ -2, 1 }, { -1, 1 }, { 0, 1 }, { 1, 1 }, { 2, 1 },
		{ -1, 2 }, { 0, 2 }, { 1, 2 },
	},
}
CombatAutomationConfig.AmmoAreaByTypeId = {
	[25757] = DIAMOND_ARROW_AREA,
	[35901] = DIAMOND_ARROW_AREA,
}

CombatAutomationConfig.DefaultAmmoByKind = {
	arrow = 3447,
	bolt = 3446,
}

-- Rings / amulets an equip slot may swap in, by unequipped item id (the equipped form,
-- transformEquipTo, counts as the same item). Rules only use items the player owns.
-- Keep in sync with client EQUIP_CATALOG.
CombatAutomationConfig.EquipItems = {
	[3048] = { slot = "ring" }, -- might ring
	[3051] = { slot = "ring" }, -- energy ring
	[3052] = { slot = "ring" }, -- life ring
	[3098] = { slot = "ring" }, -- ring of healing
	[3053] = { slot = "ring" }, -- time ring
	[3049] = { slot = "ring" }, -- stealth ring
	[3097] = { slot = "ring" }, -- dwarven ring
	[3050] = { slot = "ring" }, -- power ring
	[3091] = { slot = "ring" }, -- sword ring
	[3092] = { slot = "ring" }, -- axe ring
	[3093] = { slot = "ring" }, -- club ring
	[16114] = { slot = "ring" }, -- prismatic ring
	[3081] = { slot = "necklace" }, -- stone skin amulet
	[3083] = { slot = "necklace" }, -- garlic necklace
	[3084] = { slot = "necklace" }, -- protection amulet
	[3085] = { slot = "necklace" }, -- dragon necklace
	[3054] = { slot = "necklace" }, -- silver amulet
	[3056] = { slot = "necklace" }, -- bronze amulet
	[3082] = { slot = "necklace" }, -- elven amulet
	[3045] = { slot = "necklace" }, -- strange talisman
	[814] = { slot = "necklace" }, -- terra amulet
	[815] = { slot = "necklace" }, -- glacier amulet
	[816] = { slot = "necklace" }, -- lightning pendant
	[817] = { slot = "necklace" }, -- magma amulet
	[9302] = { slot = "necklace" }, -- sacred tree amulet
	[9303] = { slot = "necklace" }, -- leviathan's amulet
	[9304] = { slot = "necklace" }, -- shockwave amulet
	[16113] = { slot = "necklace" }, -- prismatic necklace
}
--- Shortest gap (ms) between two swaps of one body slot.
CombatAutomationConfig.EQUIP_SWAP_MS = 1000
--- Unequip margin above the equip threshold when a slot does not set one.
CombatAutomationConfig.EQUIP_RELEASE_MARGIN = 30

-- Side bar slots (client stance strip): every step is its own action with its own
-- condition, and all of them may fire in one tick. 1 = stance (step 1 stance, step 2
-- sorcerer crippling aura), 2 = equipment (step 1 ammo, 2 amulet, 3 ring).
CombatAutomationConfig.SIDE_GROUPS = { [1] = true, [2] = true }
CombatAutomationConfig.EQUIP_GROUP = 2
--- Step of the equipment slot each body slot's rule lives on.
CombatAutomationConfig.EQUIP_STEP_BY_SLOT = { necklace = 2, ring = 3 }

-- BEGIN GENERATED COMBAT AUTOMATION CATALOG
-- Generated by packages/asset-pipeline generate-combat-automation-catalog — do not edit.
CombatAutomationConfig.SpellCooldownMsByWords = {
	["exori gran ico"] = 30000,
	["exori min flam"] = 2000,
	["exori moe tempo"] = 30000,
	["exori kor tempo"] = 30000,
	["uteta res tio"] = 7200000,
	["uteta res sac"] = 7200000,
	["uteta res dru"] = 7200000,
	["uteta res eq"] = 7200000,
	["uteta res ven"] = 7200000,
	["exori mas res"] = 10000,
	["exori"] = 4000,
	["utito tempo"] = 2000,
	["exura infir ico"] = 1000,
	["exori ico"] = 6000,
	["exori infir vis"] = 2000,
	["exana ina"] = 2000,
	["exori med pug"] = 4000,
	["exeta res"] = 2000,
	["utani tempo hur"] = 2000,
	["exevo infir frigo hur"] = 4000,
	["exeta amp res"] = 2000,
	["utevo res ina"] = 2000,
	["exana kor"] = 6000,
	["exana flam"] = 6000,
	["exana mort"] = 6000,
	["exana vis"] = 6000,
	["exana pox"] = 6000,
	["utori mort"] = 40000,
	["exevo mort ora"] = 6000,
	["exori mort"] = 2000,
	["exori gran nia"] = 8000,
	["exori dir san"] = 4000,
	["exevo mas san"] = 4000,
	["exana amp res"] = 16000,
	["utori hur"] = 10000,
	["utevo grav san"] = 32000,
	["exevo tempo mas san"] = 26000,
	["exura san"] = 1000,
	["exori san"] = 2000,
	["exori pug"] = 4000,
	["utori vis"] = 30000,
	["utito dru"] = 10000,
	["utori mas sio"] = 2000,
	["exevo vis lux"] = 4000,
	["exori vis"] = 2000,
	["exevo vis hur"] = 8000,
	["utevo mas sio"] = 300000,
	["utori pox"] = 40000,
	["exevo gran mas frigo"] = 40000,
	["exori dir moe"] = 4000,
	["exori con"] = 2000,
	["exori amp kor"] = 18000,
	["exori moe"] = 12000,
	["exura med ico"] = 1000,
	["exori gran"] = 6000,
	["exevo flam hur"] = 4000,
	["exori flam"] = 2000,
	["exori mas pug"] = 4000,
	["utevo nia"] = 120000,
	["utamo tio"] = 600000,
	["exevo pan"] = 2000,
	["exori gran pug"] = 60000,
	["exevo fur frigo"] = 6000,
	["exevo fur tera"] = 6000,
	["exori min"] = 6000,
	["exevo max mort"] = 10000,
	["exevo gran vis lux"] = 6000,
	["exevo gran flam hur"] = 4000,
	["exori gran mas pug"] = 16000,
	["exori nia"] = 8000,
	["exori mas"] = 8000,
	["utani hur"] = 2000,
	["exura sio"] = 1000,
	["utura mas sio"] = 2000,
	["exevo gran mas flam"] = 40000,
	["utori san"] = 40000,
	["exevo ulus frigo"] = 22000,
	["exori frigo"] = 2000,
	["exevo frigo hur"] = 4000,
	["utori flam"] = 30000,
	["utori kor"] = 30000,
	["exura gran"] = 1000,
	["utura gran"] = 2000,
	["exura gran ico"] = 120000,
	["utana vid"] = 2000,
	["exori infir con"] = 8000,
	["exori infir min"] = 6000,
	["exani hur"] = 2000,
	["exura"] = 1000,
	["exori amp vis"] = 8000,
	["exura infir"] = 1000,
	["utamo vita"] = 14000,
	["exura gran mas res"] = 2000,
	["exura mas nia"] = 12000,
	["uteta mort"] = 30000,
	["uteta flam"] = 30000,
	["uteta vis"] = 30000,
	["utevo gran res tio"] = 0,
	["exori infir tera"] = 2000,
	["exori amp pug"] = 12000,
	["exura gran sio"] = 60000,
	["exori moe ico"] = 2000,
	["utamo mas sio"] = 2000,
	["utamo tempo"] = 2000,
	["exevo gran mas vis"] = 40000,
	["utura"] = 60000,
	["exura max vita"] = 6000,
	["exura tio sio"] = 2000,
	["exura gran san"] = 1000,
	["exori kor"] = 12000,
	["exevo infir flam hur"] = 4000,
	["utura sio"] = 10000,
	["utori con"] = 10000,
	["exori ico scu"] = 4000,
	["exori scu"] = 6000,
	["exura gran tio"] = 1000,
	["exori gran mas nia"] = 60000,
	["exori gran vis"] = 8000,
	["exori gran con"] = 8000,
	["exori gran flam"] = 8000,
	["utani gran hur"] = 2000,
	["exori gran frigo"] = 8000,
	["exevo gran frigo hur"] = 4000,
	["exori gran tera"] = 8000,
	["utevo res"] = 2000,
	["utevo gran res dru"] = 0,
	["utevo gran res eq"] = 0,
	["utevo gran res sac"] = 0,
	["utevo gran res ven"] = 0,
	["exori mas nia"] = 8000,
	["utamo tempo san"] = 4000,
	["exori infir pug"] = 2000,
	["exevo ulus tera"] = 22000,
	["exori tera"] = 2000,
	["exevo tera hur"] = 4000,
	["exori mas amp pug"] = 12000,
	["exori infir nia"] = 8000,
	["utito mas sio"] = 2000,
	["exori max vis"] = 30000,
	["exori max flam"] = 30000,
	["exura vita"] = 1000,
	["exori max frigo"] = 30000,
	["utevo vis lux"] = 2000,
	["exori max tera"] = 30000,
	["utori virtu"] = 10000,
	["utito virtu"] = 10000,
	["utura tio"] = 10000,
	["exori hur"] = 6000,
	["exura ico"] = 1000,
	["exevo gran mas tera"] = 40000,
}

CombatAutomationConfig.AllowedSpellWords = {
	["exori gran ico"] = true,
	["exori min flam"] = true,
	["exori moe tempo"] = true,
	["exori kor tempo"] = true,
	["uteta res tio"] = true,
	["uteta res sac"] = true,
	["uteta res dru"] = true,
	["uteta res eq"] = true,
	["uteta res ven"] = true,
	["exori mas res"] = true,
	["exori"] = true,
	["utito tempo"] = true,
	["exura infir ico"] = true,
	["exori ico"] = true,
	["exori infir vis"] = true,
	["exana ina"] = true,
	["exori med pug"] = true,
	["exeta res"] = true,
	["utani tempo hur"] = true,
	["exevo infir frigo hur"] = true,
	["exeta amp res"] = true,
	["utevo res ina"] = true,
	["exana kor"] = true,
	["exana flam"] = true,
	["exana mort"] = true,
	["exana vis"] = true,
	["exana pox"] = true,
	["utori mort"] = true,
	["exevo mort ora"] = true,
	["exori mort"] = true,
	["exori gran nia"] = true,
	["exori dir san"] = true,
	["exevo mas san"] = true,
	["exana amp res"] = true,
	["utori hur"] = true,
	["utevo grav san"] = true,
	["exevo tempo mas san"] = true,
	["exura san"] = true,
	["exori san"] = true,
	["exori pug"] = true,
	["utori vis"] = true,
	["utito dru"] = true,
	["utori mas sio"] = true,
	["exevo vis lux"] = true,
	["exori vis"] = true,
	["exevo vis hur"] = true,
	["utevo mas sio"] = true,
	["utori pox"] = true,
	["exevo gran mas frigo"] = true,
	["exori dir moe"] = true,
	["exori con"] = true,
	["exori amp kor"] = true,
	["exori moe"] = true,
	["exura med ico"] = true,
	["exori gran"] = true,
	["exevo flam hur"] = true,
	["exori flam"] = true,
	["exori mas pug"] = true,
	["utevo nia"] = true,
	["utamo tio"] = true,
	["exevo pan"] = true,
	["exori gran pug"] = true,
	["exevo fur frigo"] = true,
	["exevo fur tera"] = true,
	["exori min"] = true,
	["exevo max mort"] = true,
	["exevo gran vis lux"] = true,
	["exevo gran flam hur"] = true,
	["exori gran mas pug"] = true,
	["exori nia"] = true,
	["exori mas"] = true,
	["utani hur"] = true,
	["exura sio"] = true,
	["utura mas sio"] = true,
	["exevo gran mas flam"] = true,
	["utori san"] = true,
	["exevo ulus frigo"] = true,
	["exori frigo"] = true,
	["exevo frigo hur"] = true,
	["utori flam"] = true,
	["utori kor"] = true,
	["exura gran"] = true,
	["utura gran"] = true,
	["exura gran ico"] = true,
	["utana vid"] = true,
	["exori infir con"] = true,
	["exori infir min"] = true,
	["exani hur"] = true,
	["exura"] = true,
	["exori amp vis"] = true,
	["exura infir"] = true,
	["utamo vita"] = true,
	["exura gran mas res"] = true,
	["exura mas nia"] = true,
	["uteta mort"] = true,
	["uteta flam"] = true,
	["uteta vis"] = true,
	["utevo gran res tio"] = true,
	["exori infir tera"] = true,
	["exori amp pug"] = true,
	["exura gran sio"] = true,
	["exori moe ico"] = true,
	["utamo mas sio"] = true,
	["utamo tempo"] = true,
	["exevo gran mas vis"] = true,
	["utura"] = true,
	["exura max vita"] = true,
	["exura tio sio"] = true,
	["exura gran san"] = true,
	["exori kor"] = true,
	["exevo infir flam hur"] = true,
	["utura sio"] = true,
	["utori con"] = true,
	["exori ico scu"] = true,
	["exori scu"] = true,
	["exura gran tio"] = true,
	["exori gran mas nia"] = true,
	["exori gran vis"] = true,
	["exori gran con"] = true,
	["exori gran flam"] = true,
	["utani gran hur"] = true,
	["exori gran frigo"] = true,
	["exevo gran frigo hur"] = true,
	["exori gran tera"] = true,
	["utevo res"] = true,
	["utevo gran res dru"] = true,
	["utevo gran res eq"] = true,
	["utevo gran res sac"] = true,
	["utevo gran res ven"] = true,
	["exori mas nia"] = true,
	["utamo tempo san"] = true,
	["exori infir pug"] = true,
	["exevo ulus tera"] = true,
	["exori tera"] = true,
	["exevo tera hur"] = true,
	["exori mas amp pug"] = true,
	["exori infir nia"] = true,
	["utito mas sio"] = true,
	["exori max vis"] = true,
	["exori max flam"] = true,
	["exura vita"] = true,
	["exori max frigo"] = true,
	["utevo vis lux"] = true,
	["exori max tera"] = true,
	["utori virtu"] = true,
	["utito virtu"] = true,
	["utura tio"] = true,
	["exori hur"] = true,
	["exura ico"] = true,
	["exevo gran mas tera"] = true,
}

CombatAutomationConfig.SpellWordsById = {
	exori_gran_ico = "exori gran ico",
	exori_min_flam = "exori min flam",
	exori_moe_tempo = "exori moe tempo",
	exori_kor_tempo = "exori kor tempo",
	uteta_res_tio = "uteta res tio",
	uteta_res_sac = "uteta res sac",
	uteta_res_dru = "uteta res dru",
	uteta_res_eq = "uteta res eq",
	uteta_res_ven = "uteta res ven",
	exori_mas_res = "exori mas res",
	exori = "exori",
	utito_tempo = "utito tempo",
	exura_infir_ico = "exura infir ico",
	exori_ico = "exori ico",
	exori_infir_vis = "exori infir vis",
	exana_ina = "exana ina",
	exori_med_pug = "exori med pug",
	exeta_res = "exeta res",
	utani_tempo_hur = "utani tempo hur",
	exevo_infir_frigo_hur = "exevo infir frigo hur",
	exeta_amp_res = "exeta amp res",
	utevo_res_ina = "utevo res ina",
	exana_kor = "exana kor",
	exana_flam = "exana flam",
	exana_mort = "exana mort",
	exana_vis = "exana vis",
	exana_pox = "exana pox",
	utori_mort = "utori mort",
	exevo_mort_ora = "exevo mort ora",
	exori_mort = "exori mort",
	exori_gran_nia = "exori gran nia",
	exori_dir_san = "exori dir san",
	exevo_mas_san = "exevo mas san",
	exana_amp_res = "exana amp res",
	utori_hur = "utori hur",
	utevo_grav_san = "utevo grav san",
	exevo_tempo_mas_san = "exevo tempo mas san",
	exura_san = "exura san",
	exori_san = "exori san",
	exori_pug = "exori pug",
	utori_vis = "utori vis",
	utito_dru = "utito dru",
	utori_mas_sio = "utori mas sio",
	exevo_vis_lux = "exevo vis lux",
	exori_vis = "exori vis",
	exevo_vis_hur = "exevo vis hur",
	utevo_mas_sio = "utevo mas sio",
	utori_pox = "utori pox",
	exevo_gran_mas_frigo = "exevo gran mas frigo",
	exori_dir_moe = "exori dir moe",
	exori_con = "exori con",
	exori_amp_kor = "exori amp kor",
	exori_moe = "exori moe",
	exura_med_ico = "exura med ico",
	exori_gran = "exori gran",
	exevo_flam_hur = "exevo flam hur",
	exori_flam = "exori flam",
	exori_mas_pug = "exori mas pug",
	utevo_nia = "utevo nia",
	utamo_tio = "utamo tio",
	exevo_pan = "exevo pan",
	exori_gran_pug = "exori gran pug",
	exevo_fur_frigo = "exevo fur frigo",
	exevo_fur_tera = "exevo fur tera",
	exori_min = "exori min",
	exevo_max_mort = "exevo max mort",
	exevo_gran_vis_lux = "exevo gran vis lux",
	exevo_gran_flam_hur = "exevo gran flam hur",
	exori_gran_mas_pug = "exori gran mas pug",
	exori_nia = "exori nia",
	exori_mas = "exori mas",
	utani_hur = "utani hur",
	exura_sio = "exura sio",
	utura_mas_sio = "utura mas sio",
	exevo_gran_mas_flam = "exevo gran mas flam",
	utori_san = "utori san",
	exevo_ulus_frigo = "exevo ulus frigo",
	exori_frigo = "exori frigo",
	exevo_frigo_hur = "exevo frigo hur",
	utori_flam = "utori flam",
	utori_kor = "utori kor",
	exura_gran = "exura gran",
	utura_gran = "utura gran",
	exura_gran_ico = "exura gran ico",
	utana_vid = "utana vid",
	exori_infir_con = "exori infir con",
	exori_infir_min = "exori infir min",
	exani_hur = "exani hur",
	exura = "exura",
	exori_amp_vis = "exori amp vis",
	exura_infir = "exura infir",
	utamo_vita = "utamo vita",
	exura_gran_mas_res = "exura gran mas res",
	exura_mas_nia = "exura mas nia",
	uteta_mort = "uteta mort",
	uteta_flam = "uteta flam",
	uteta_vis = "uteta vis",
	utevo_gran_res_tio = "utevo gran res tio",
	exori_infir_tera = "exori infir tera",
	exori_amp_pug = "exori amp pug",
	exura_gran_sio = "exura gran sio",
	exori_moe_ico = "exori moe ico",
	utamo_mas_sio = "utamo mas sio",
	utamo_tempo = "utamo tempo",
	exevo_gran_mas_vis = "exevo gran mas vis",
	utura = "utura",
	exura_max_vita = "exura max vita",
	exura_tio_sio = "exura tio sio",
	exura_gran_san = "exura gran san",
	exori_kor = "exori kor",
	exevo_infir_flam_hur = "exevo infir flam hur",
	utura_sio = "utura sio",
	utori_con = "utori con",
	exori_ico_scu = "exori ico scu",
	exori_scu = "exori scu",
	exura_gran_tio = "exura gran tio",
	exori_gran_mas_nia = "exori gran mas nia",
	exori_gran_vis = "exori gran vis",
	exori_gran_con = "exori gran con",
	exori_gran_flam = "exori gran flam",
	utani_gran_hur = "utani gran hur",
	exori_gran_frigo = "exori gran frigo",
	exevo_gran_frigo_hur = "exevo gran frigo hur",
	exori_gran_tera = "exori gran tera",
	utevo_res = "utevo res",
	utevo_gran_res_dru = "utevo gran res dru",
	utevo_gran_res_eq = "utevo gran res eq",
	utevo_gran_res_sac = "utevo gran res sac",
	utevo_gran_res_ven = "utevo gran res ven",
	exori_mas_nia = "exori mas nia",
	utamo_tempo_san = "utamo tempo san",
	exori_infir_pug = "exori infir pug",
	exevo_ulus_tera = "exevo ulus tera",
	exori_tera = "exori tera",
	exevo_tera_hur = "exevo tera hur",
	exori_mas_amp_pug = "exori mas amp pug",
	exori_infir_nia = "exori infir nia",
	utito_mas_sio = "utito mas sio",
	exori_max_vis = "exori max vis",
	exori_max_flam = "exori max flam",
	exura_vita = "exura vita",
	exori_max_frigo = "exori max frigo",
	utevo_vis_lux = "utevo vis lux",
	exori_max_tera = "exori max tera",
	utori_virtu = "utori virtu",
	utito_virtu = "utito virtu",
	utura_tio = "utura tio",
	exori_hur = "exori hur",
	exura_ico = "exura ico",
	exevo_gran_mas_tera = "exevo gran mas tera",
}

CombatAutomationConfig.SpellVocationsById = {
	exori_gran_ico = { "knight", "elite knight" },
	exori_min_flam = { "druid", "elder druid", "sorcerer", "master sorcerer" },
	exori_moe_tempo = { "master sorcerer" },
	exori_kor_tempo = { "master sorcerer" },
	uteta_res_tio = { "monk", "exalted monk" },
	uteta_res_sac = { "paladin", "royal paladin" },
	uteta_res_dru = { "druid", "elder druid" },
	uteta_res_eq = { "knight", "elite knight" },
	uteta_res_ven = { "sorcerer", "master sorcerer" },
	exori_mas_res = { "monk", "exalted monk" },
	exori = { "knight", "elite knight" },
	utito_tempo = { "elite knight" },
	exura_infir_ico = { "knight", "elite knight" },
	exori_ico = { "knight", "elite knight" },
	exori_infir_vis = { "sorcerer", "master sorcerer" },
	exana_ina = { "paladin", "royal paladin" },
	exori_med_pug = { "monk", "exalted monk" },
	exeta_res = { "elite knight" },
	utani_tempo_hur = { "knight", "elite knight" },
	exevo_infir_frigo_hur = { "druid", "elder druid" },
	exeta_amp_res = { "knight", "elite knight" },
	utevo_res_ina = { "druid", "elder druid", "sorcerer", "master sorcerer" },
	exana_kor = { "druid", "elder druid", "knight", "elite knight" },
	exana_flam = { "druid", "elder druid" },
	exana_mort = { "paladin", "royal paladin" },
	exana_vis = { "druid", "elder druid" },
	exana_pox = { "druid", "elder druid", "knight", "elite knight", "paladin", "royal paladin", "sorcerer", "master sorcerer", "monk", "exalted monk" },
	utori_mort = { "sorcerer", "master sorcerer" },
	exevo_mort_ora = { "sorcerer", "master sorcerer" },
	exori_mort = { "sorcerer", "master sorcerer" },
	exori_gran_nia = { "monk", "exalted monk" },
	exori_dir_san = { "paladin", "royal paladin" },
	exevo_mas_san = { "paladin", "royal paladin" },
	exana_amp_res = { "royal paladin" },
	utori_hur = { "royal paladin" },
	utevo_grav_san = { "paladin", "royal paladin" },
	exevo_tempo_mas_san = { "paladin", "royal paladin" },
	exura_san = { "paladin", "royal paladin" },
	exori_san = { "paladin", "royal paladin" },
	exori_pug = { "monk", "exalted monk" },
	utori_vis = { "sorcerer", "master sorcerer" },
	utito_dru = { "elder druid" },
	utori_mas_sio = { "sorcerer", "master sorcerer" },
	exevo_vis_lux = { "sorcerer", "master sorcerer" },
	exori_vis = { "druid", "elder druid", "sorcerer", "master sorcerer" },
	exevo_vis_hur = { "sorcerer", "master sorcerer" },
	utevo_mas_sio = { "monk", "exalted monk" },
	utori_pox = { "druid", "elder druid" },
	exevo_gran_mas_frigo = { "druid", "elder druid" },
	exori_dir_moe = { "paladin", "royal paladin" },
	exori_con = { "paladin", "royal paladin" },
	exori_amp_kor = { "knight", "elite knight" },
	exori_moe = { "sorcerer", "master sorcerer" },
	exura_med_ico = { "knight", "elite knight" },
	exori_gran = { "knight", "elite knight" },
	exevo_flam_hur = { "sorcerer", "master sorcerer" },
	exori_flam = { "sorcerer", "druid", "master sorcerer", "elder druid" },
	exori_mas_pug = { "monk", "exalted monk" },
	utevo_nia = { "monk", "exalted monk" },
	utamo_tio = { "monk", "exalted monk" },
	exevo_pan = { "druid", "elder druid" },
	exori_gran_pug = { "monk", "exalted monk" },
	exevo_fur_frigo = { "druid", "elder druid" },
	exevo_fur_tera = { "druid", "elder druid" },
	exori_min = { "knight", "elite knight" },
	exevo_max_mort = { "sorcerer", "master sorcerer" },
	exevo_gran_vis_lux = { "sorcerer", "master sorcerer" },
	exevo_gran_flam_hur = { "sorcerer", "master sorcerer" },
	exori_gran_mas_pug = { "monk", "exalted monk" },
	exori_nia = { "monk", "exalted monk" },
	exori_mas = { "knight", "elite knight" },
	utani_hur = { "druid", "elder druid", "knight", "elite knight", "paladin", "royal paladin", "sorcerer", "master sorcerer", "monk", "exalted monk" },
	exura_sio = { "druid", "elder druid" },
	utura_mas_sio = { "druid", "elder druid" },
	exevo_gran_mas_flam = { "sorcerer", "master sorcerer" },
	utori_san = { "paladin", "royal paladin" },
	exevo_ulus_frigo = { "druid", "elder druid" },
	exori_frigo = { "druid", "sorcerer", "elder druid", "master sorcerer" },
	exevo_frigo_hur = { "druid", "elder druid" },
	utori_flam = { "sorcerer", "master sorcerer" },
	utori_kor = { "knight", "elite knight", "monk", "exalted monk" },
	exura_gran = { "druid", "elder druid", "paladin", "royal paladin", "sorcerer", "master sorcerer", "monk", "exalted monk" },
	utura_gran = { "knight", "elite knight", "paladin", "royal paladin" },
	exura_gran_ico = { "knight", "elite knight" },
	utana_vid = { "druid", "elder druid", "sorcerer", "master sorcerer" },
	exori_infir_con = { "paladin", "royal paladin" },
	exori_infir_min = { "knight", "elite knight" },
	exani_hur = { "druid", "elder druid", "knight", "elite knight", "paladin", "royal paladin", "sorcerer", "master sorcerer", "monk", "exalted monk" },
	exura = { "druid", "elder druid", "paladin", "royal paladin", "sorcerer", "master sorcerer", "monk", "exalted monk" },
	exori_amp_vis = { "sorcerer", "master sorcerer" },
	exura_infir = { "druid", "elder druid", "paladin", "royal paladin", "sorcerer", "master sorcerer", "monk", "exalted monk" },
	utamo_vita = { "druid", "elder druid", "sorcerer", "master sorcerer" },
	exura_gran_mas_res = { "druid", "elder druid" },
	exura_mas_nia = { "monk", "exalted monk" },
	uteta_mort = { "master sorcerer" },
	uteta_flam = { "master sorcerer" },
	uteta_vis = { "master sorcerer" },
	utevo_gran_res_tio = { "monk", "exalted monk" },
	exori_infir_tera = { "druid", "elder druid" },
	exori_amp_pug = { "monk", "exalted monk" },
	exura_gran_sio = { "druid", "elder druid" },
	exori_moe_ico = { "druid", "elder druid" },
	utamo_mas_sio = { "paladin", "royal paladin" },
	utamo_tempo = { "elite knight" },
	exevo_gran_mas_vis = { "sorcerer", "master sorcerer" },
	utura = { "knight", "elite knight", "paladin", "royal paladin" },
	exura_max_vita = { "druid", "sorcerer", "elder druid", "master sorcerer" },
	exura_tio_sio = { "monk", "exalted monk" },
	exura_gran_san = { "paladin", "royal paladin" },
	exori_kor = { "sorcerer", "master sorcerer" },
	exevo_infir_flam_hur = { "sorcerer", "master sorcerer" },
	utura_sio = { "elder druid" },
	utori_con = { "royal paladin" },
	exori_ico_scu = { "knight", "elite knight" },
	exori_scu = { "knight", "elite knight" },
	exura_gran_tio = { "monk", "exalted monk" },
	exori_gran_mas_nia = { "monk", "exalted monk" },
	exori_gran_vis = { "sorcerer", "master sorcerer" },
	exori_gran_con = { "paladin", "royal paladin" },
	exori_gran_flam = { "sorcerer", "master sorcerer" },
	utani_gran_hur = { "druid", "elder druid", "sorcerer", "master sorcerer", "monk", "exalted monk" },
	exori_gran_frigo = { "druid", "elder druid" },
	exevo_gran_frigo_hur = { "druid", "elder druid" },
	exori_gran_tera = { "druid", "elder druid" },
	utevo_res = { "druid", "sorcerer", "elder druid", "master sorcerer" },
	utevo_gran_res_dru = { "druid", "elder druid" },
	utevo_gran_res_eq = { "knight", "elite knight" },
	utevo_gran_res_sac = { "paladin", "royal paladin" },
	utevo_gran_res_ven = { "sorcerer", "master sorcerer" },
	exori_mas_nia = { "monk", "exalted monk" },
	utamo_tempo_san = { "paladin", "royal paladin" },
	exori_infir_pug = { "monk", "exalted monk" },
	exevo_ulus_tera = { "druid", "elder druid" },
	exori_tera = { "druid", "elder druid", "sorcerer", "master sorcerer" },
	exevo_tera_hur = { "druid", "elder druid" },
	exori_mas_amp_pug = { "monk", "exalted monk" },
	exori_infir_nia = { "monk", "exalted monk" },
	utito_mas_sio = { "knight", "elite knight" },
	exori_max_vis = { "sorcerer", "master sorcerer" },
	exori_max_flam = { "sorcerer", "master sorcerer" },
	exura_vita = { "druid", "elder druid", "sorcerer", "master sorcerer" },
	exori_max_frigo = { "druid", "elder druid" },
	utevo_vis_lux = { "druid", "elder druid", "sorcerer", "master sorcerer" },
	exori_max_tera = { "druid", "elder druid" },
	utori_virtu = { "exalted monk" },
	utito_virtu = { "exalted monk" },
	utura_tio = { "exalted monk" },
	exori_hur = { "knight", "elite knight" },
	exura_ico = { "knight", "elite knight" },
	exevo_gran_mas_tera = { "druid", "elder druid" },
}

CombatAutomationConfig.SpellMinLevelById = {
	exori_gran_ico = 110,
	exori_min_flam = 6,
	exori_moe_tempo = 175,
	exori_kor_tempo = 175,
	uteta_res_tio = 300,
	uteta_res_sac = 300,
	uteta_res_dru = 300,
	uteta_res_eq = 300,
	uteta_res_ven = 300,
	exori_mas_res = 175,
	exori = 35,
	utito_tempo = 20,
	exura_infir_ico = 1,
	exori_ico = 16,
	exori_infir_vis = 1,
	exana_ina = 26,
	exori_med_pug = 70,
	exeta_res = 20,
	utani_tempo_hur = 25,
	exevo_infir_frigo_hur = 1,
	exeta_amp_res = 150,
	utevo_res_ina = 23,
	exana_kor = 45,
	exana_flam = 30,
	exana_mort = 80,
	exana_vis = 22,
	exana_pox = 10,
	utori_mort = 75,
	exevo_mort_ora = 120,
	exori_mort = 16,
	exori_gran_nia = 125,
	exori_dir_san = 70,
	exevo_mas_san = 50,
	exana_amp_res = 250,
	utori_hur = 20,
	utevo_grav_san = 300,
	exevo_tempo_mas_san = 300,
	exura_san = 35,
	exori_san = 40,
	exori_pug = 14,
	utori_vis = 34,
	utito_dru = 20,
	utori_mas_sio = 32,
	exevo_vis_lux = 23,
	exori_vis = 12,
	exevo_vis_hur = 38,
	utevo_mas_sio = 32,
	utori_pox = 50,
	exevo_gran_mas_frigo = 60,
	exori_dir_moe = 60,
	exori_con = 23,
	exori_amp_kor = 300,
	exori_moe = 275,
	exura_med_ico = 300,
	exori_gran = 90,
	exevo_flam_hur = 18,
	exori_flam = 14,
	exori_mas_pug = 35,
	utevo_nia = 275,
	utamo_tio = 150,
	exevo_pan = 14,
	exori_gran_pug = 110,
	exevo_fur_frigo = 90,
	exevo_fur_tera = 80,
	exori_min = 70,
	exevo_max_mort = 66,
	exevo_gran_vis_lux = 29,
	exevo_gran_flam_hur = 38,
	exori_gran_mas_pug = 90,
	exori_nia = 18,
	exori_mas = 33,
	utani_hur = 14,
	exura_sio = 18,
	utura_mas_sio = 32,
	exevo_gran_mas_flam = 60,
	utori_san = 70,
	exevo_ulus_frigo = 300,
	exori_frigo = 8,
	exevo_frigo_hur = 18,
	utori_flam = 26,
	utori_kor = 40,
	exura_gran = 20,
	utura_gran = 100,
	exura_gran_ico = 80,
	utana_vid = 35,
	exori_infir_con = 1,
	exori_infir_min = 1,
	exani_hur = 12,
	exura = 8,
	exori_amp_vis = 55,
	exura_infir = 1,
	utamo_vita = 14,
	exura_gran_mas_res = 36,
	exura_mas_nia = 150,
	uteta_mort = 20,
	uteta_flam = 20,
	uteta_vis = 20,
	utevo_gran_res_tio = 200,
	exori_infir_tera = 1,
	exori_amp_pug = 30,
	exura_gran_sio = 300,
	exori_moe_ico = 16,
	utamo_mas_sio = 32,
	utamo_tempo = 20,
	exevo_gran_mas_vis = 55,
	utura = 50,
	exura_max_vita = 300,
	exura_tio_sio = 18,
	exura_gran_san = 60,
	exori_kor = 275,
	exevo_infir_flam_hur = 1,
	utura_sio = 20,
	utori_con = 20,
	exori_ico_scu = 18,
	exori_scu = 30,
	exura_gran_tio = 80,
	exori_gran_mas_nia = 300,
	exori_gran_vis = 80,
	exori_gran_con = 90,
	exori_gran_flam = 70,
	utani_gran_hur = 20,
	exori_gran_frigo = 80,
	exevo_gran_frigo_hur = 40,
	exori_gran_tera = 70,
	utevo_res = 25,
	utevo_gran_res_dru = 200,
	utevo_gran_res_eq = 200,
	utevo_gran_res_sac = 200,
	utevo_gran_res_ven = 200,
	exori_mas_nia = 60,
	utamo_tempo_san = 55,
	exori_infir_pug = 1,
	exevo_ulus_tera = 300,
	exori_tera = 13,
	exevo_tera_hur = 38,
	exori_mas_amp_pug = 120,
	exori_infir_nia = 1,
	utito_mas_sio = 32,
	exori_max_vis = 100,
	exori_max_flam = 90,
	exura_vita = 30,
	exori_max_frigo = 100,
	utevo_vis_lux = 26,
	exori_max_tera = 90,
	utori_virtu = 20,
	utito_virtu = 20,
	utura_tio = 20,
	exori_hur = 28,
	exura_ico = 8,
	exevo_gran_mas_tera = 55,
}

CombatAutomationConfig.SpellGroupById = {
	exori_gran_ico = "attack",
	exori_min_flam = "attack",
	exori_moe_tempo = "support",
	exori_kor_tempo = "support",
	uteta_res_tio = "support",
	uteta_res_sac = "support",
	uteta_res_dru = "support",
	uteta_res_eq = "support",
	uteta_res_ven = "support",
	exori_mas_res = "support",
	exori = "attack",
	utito_tempo = "stance",
	exura_infir_ico = "healing",
	exori_ico = "attack",
	exori_infir_vis = "attack",
	exana_ina = "support",
	exori_med_pug = "attack",
	exeta_res = "support",
	utani_tempo_hur = "support",
	exevo_infir_frigo_hur = "attack",
	exeta_amp_res = "support",
	utevo_res_ina = "support",
	exana_kor = "healing",
	exana_flam = "healing",
	exana_mort = "healing",
	exana_vis = "healing",
	exana_pox = "healing",
	utori_mort = "attack",
	exevo_mort_ora = "attack",
	exori_mort = "attack",
	exori_gran_nia = "attack",
	exori_dir_san = "attack",
	exevo_mas_san = "attack",
	exana_amp_res = "support",
	utori_hur = "stance",
	utevo_grav_san = "support",
	exevo_tempo_mas_san = "attack",
	exura_san = "healing",
	exori_san = "attack",
	exori_pug = "attack",
	utori_vis = "attack",
	utito_dru = "stance",
	utori_mas_sio = "support",
	exevo_vis_lux = "attack",
	exori_vis = "attack",
	exevo_vis_hur = "attack",
	utevo_mas_sio = "support",
	utori_pox = "attack",
	exevo_gran_mas_frigo = "attack",
	exori_dir_moe = "attack",
	exori_con = "attack",
	exori_amp_kor = "attack",
	exori_moe = "support",
	exura_med_ico = "healing",
	exori_gran = "attack",
	exevo_flam_hur = "attack",
	exori_flam = "attack",
	exori_mas_pug = "attack",
	utevo_nia = "support",
	utamo_tio = "support",
	exevo_pan = "support",
	exori_gran_pug = "attack",
	exevo_fur_frigo = "attack",
	exevo_fur_tera = "attack",
	exori_min = "attack",
	exevo_max_mort = "attack",
	exevo_gran_vis_lux = "attack",
	exevo_gran_flam_hur = "attack",
	exori_gran_mas_pug = "attack",
	exori_nia = "attack",
	exori_mas = "attack",
	utani_hur = "support",
	exura_sio = "healing",
	utura_mas_sio = "support",
	exevo_gran_mas_flam = "attack",
	utori_san = "attack",
	exevo_ulus_frigo = "attack",
	exori_frigo = "attack",
	exevo_frigo_hur = "attack",
	utori_flam = "attack",
	utori_kor = "attack",
	exura_gran = "healing",
	utura_gran = "healing",
	exura_gran_ico = "healing",
	utana_vid = "support",
	exori_infir_con = "attack",
	exori_infir_min = "attack",
	exani_hur = "support",
	exura = "healing",
	exori_amp_vis = "attack",
	exura_infir = "healing",
	utamo_vita = "shield",
	exura_gran_mas_res = "healing",
	exura_mas_nia = "healing",
	uteta_mort = "stance",
	uteta_flam = "stance",
	uteta_vis = "stance",
	utevo_gran_res_tio = "support",
	exori_infir_tera = "attack",
	exori_amp_pug = "attack",
	exura_gran_sio = "healing",
	exori_moe_ico = "attack",
	utamo_mas_sio = "support",
	utamo_tempo = "stance",
	exevo_gran_mas_vis = "attack",
	utura = "healing",
	exura_max_vita = "healing",
	exura_tio_sio = "healing",
	exura_gran_san = "healing",
	exori_kor = "support",
	exevo_infir_flam_hur = "attack",
	utura_sio = "stance",
	utori_con = "stance",
	exori_ico_scu = "attack",
	exori_scu = "attack",
	exura_gran_tio = "healing",
	exori_gran_mas_nia = "attack",
	exori_gran_vis = "attack",
	exori_gran_con = "attack",
	exori_gran_flam = "attack",
	utani_gran_hur = "support",
	exori_gran_frigo = "attack",
	exevo_gran_frigo_hur = "attack",
	exori_gran_tera = "attack",
	utevo_res = "support",
	utevo_gran_res_dru = "support",
	utevo_gran_res_eq = "support",
	utevo_gran_res_sac = "support",
	utevo_gran_res_ven = "support",
	exori_mas_nia = "attack",
	utamo_tempo_san = "support",
	exori_infir_pug = "attack",
	exevo_ulus_tera = "attack",
	exori_tera = "attack",
	exevo_tera_hur = "attack",
	exori_mas_amp_pug = "attack",
	exori_infir_nia = "attack",
	utito_mas_sio = "support",
	exori_max_vis = "attack",
	exori_max_flam = "attack",
	exura_vita = "healing",
	exori_max_frigo = "attack",
	utevo_vis_lux = "support",
	exori_max_tera = "attack",
	utori_virtu = "stance",
	utito_virtu = "stance",
	utura_tio = "stance",
	exori_hur = "attack",
	exura_ico = "healing",
	exevo_gran_mas_tera = "attack",
}

CombatAutomationConfig.SpellAreaById = {
	exori_gran_ico = { kind = "target", shape = "single", radius = 0 },
	exori_min_flam = { kind = "target", shape = "single", radius = 0 },
	exori_moe_tempo = { kind = "self", shape = "single", radius = 0 },
	exori_kor_tempo = { kind = "self", shape = "single", radius = 0 },
	uteta_res_tio = { kind = "self", shape = "single", radius = 0 },
	uteta_res_sac = { kind = "self", shape = "single", radius = 0 },
	uteta_res_dru = { kind = "self", shape = "single", radius = 0 },
	uteta_res_eq = { kind = "self", shape = "single", radius = 0 },
	uteta_res_ven = { kind = "self", shape = "single", radius = 0 },
	exori_mas_res = {
		kind = "direction",
		shape = "wave",
		radius = 0,
		byDir = {
		[0] = { {-6, 0}, {-5, -2}, {-5, -1}, {-5, 0}, {-4, -3}, {-4, -2}, {-4, -1}, {-4, 0}, {-3, -4}, {-3, -3}, {-3, -2}, {-3, -1}, {-3, 0}, {-2, -5}, {-2, -4}, {-2, -3}, {-2, -2}, {-2, -1}, {-2, 0}, {-1, -5}, {-1, -4}, {-1, -3}, {-1, -2}, {0, -6}, {0, -5}, {0, -4}, {0, -3}, {0, -2}, {0, -1}, {1, -5}, {1, -4}, {1, -3}, {1, -2}, {2, -5}, {2, -4}, {2, -3}, {2, -2}, {2, -1}, {2, 0}, {3, -4}, {3, -3}, {3, -2}, {3, -1}, {3, 0}, {4, -3}, {4, -2}, {4, -1}, {4, 0}, {5, -2}, {5, -1}, {5, 0}, {6, 0} },
		[1] = { {0, -6}, {0, -5}, {0, -4}, {0, -3}, {0, -2}, {0, 2}, {0, 3}, {0, 4}, {0, 5}, {0, 6}, {1, -5}, {1, -4}, {1, -3}, {1, -2}, {1, 0}, {1, 2}, {1, 3}, {1, 4}, {1, 5}, {2, -5}, {2, -4}, {2, -3}, {2, -2}, {2, -1}, {2, 0}, {2, 1}, {2, 2}, {2, 3}, {2, 4}, {2, 5}, {3, -4}, {3, -3}, {3, -2}, {3, -1}, {3, 0}, {3, 1}, {3, 2}, {3, 3}, {3, 4}, {4, -3}, {4, -2}, {4, -1}, {4, 0}, {4, 1}, {4, 2}, {4, 3}, {5, -2}, {5, -1}, {5, 0}, {5, 1}, {5, 2}, {6, 0} },
		[2] = { {-6, 0}, {-5, 0}, {-5, 1}, {-5, 2}, {-4, 0}, {-4, 1}, {-4, 2}, {-4, 3}, {-3, 0}, {-3, 1}, {-3, 2}, {-3, 3}, {-3, 4}, {-2, 0}, {-2, 1}, {-2, 2}, {-2, 3}, {-2, 4}, {-2, 5}, {-1, 2}, {-1, 3}, {-1, 4}, {-1, 5}, {0, 1}, {0, 2}, {0, 3}, {0, 4}, {0, 5}, {0, 6}, {1, 2}, {1, 3}, {1, 4}, {1, 5}, {2, 0}, {2, 1}, {2, 2}, {2, 3}, {2, 4}, {2, 5}, {3, 0}, {3, 1}, {3, 2}, {3, 3}, {3, 4}, {4, 0}, {4, 1}, {4, 2}, {4, 3}, {5, 0}, {5, 1}, {5, 2}, {6, 0} },
		[3] = { {-6, 0}, {-5, -2}, {-5, -1}, {-5, 0}, {-5, 1}, {-5, 2}, {-4, -3}, {-4, -2}, {-4, -1}, {-4, 0}, {-4, 1}, {-4, 2}, {-4, 3}, {-3, -4}, {-3, -3}, {-3, -2}, {-3, -1}, {-3, 0}, {-3, 1}, {-3, 2}, {-3, 3}, {-3, 4}, {-2, -5}, {-2, -4}, {-2, -3}, {-2, -2}, {-2, -1}, {-2, 0}, {-2, 1}, {-2, 2}, {-2, 3}, {-2, 4}, {-2, 5}, {-1, -5}, {-1, -4}, {-1, -3}, {-1, -2}, {-1, 0}, {-1, 2}, {-1, 3}, {-1, 4}, {-1, 5}, {0, -6}, {0, -5}, {0, -4}, {0, -3}, {0, -2}, {0, 2}, {0, 3}, {0, 4}, {0, 5}, {0, 6} },
	},
	},
	exori = { kind = "self", shape = "square", radius = 1, tiles = { {-1, -1}, {-1, 0}, {-1, 1}, {0, -1}, {0, 0}, {0, 1}, {1, -1}, {1, 0}, {1, 1} } },
	utito_tempo = { kind = "self", shape = "single", radius = 0 },
	exura_infir_ico = { kind = "self", shape = "single", radius = 0 },
	exori_ico = { kind = "target", shape = "single", radius = 0 },
	exori_infir_vis = { kind = "target", shape = "single", radius = 0 },
	exana_ina = { kind = "self", shape = "circle", radius = 3, tiles = { {-3, -1}, {-3, 0}, {-3, 1}, {-2, -2}, {-2, -1}, {-2, 0}, {-2, 1}, {-2, 2}, {-1, -3}, {-1, -2}, {-1, -1}, {-1, 0}, {-1, 1}, {-1, 2}, {-1, 3}, {0, -3}, {0, -2}, {0, -1}, {0, 0}, {0, 1}, {0, 2}, {0, 3}, {1, -3}, {1, -2}, {1, -1}, {1, 0}, {1, 1}, {1, 2}, {1, 3}, {2, -2}, {2, -1}, {2, 0}, {2, 1}, {2, 2}, {3, -1}, {3, 0}, {3, 1} } },
	exori_med_pug = { kind = "self", shape = "single", radius = 0 },
	exeta_res = { kind = "self", shape = "square", radius = 1, tiles = { {-1, -1}, {-1, 0}, {-1, 1}, {0, -1}, {0, 0}, {0, 1}, {1, -1}, {1, 0}, {1, 1} } },
	utani_tempo_hur = { kind = "self", shape = "single", radius = 0 },
	exevo_infir_frigo_hur = {
		kind = "direction",
		shape = "wave",
		radius = 0,
		byDir = {
		[0] = { {-2, -4}, {-1, -4}, {-1, -3}, {-1, -2}, {0, -4}, {0, -3}, {0, -2}, {0, -1}, {1, -4}, {1, -3}, {1, -2}, {2, -4} },
		[1] = { {1, 0}, {2, -1}, {2, 0}, {2, 1}, {3, -1}, {3, 0}, {3, 1}, {4, -2}, {4, -1}, {4, 0}, {4, 1}, {4, 2} },
		[2] = { {-2, 4}, {-1, 2}, {-1, 3}, {-1, 4}, {0, 1}, {0, 2}, {0, 3}, {0, 4}, {1, 2}, {1, 3}, {1, 4}, {2, 4} },
		[3] = { {-4, -2}, {-4, -1}, {-4, 0}, {-4, 1}, {-4, 2}, {-3, -1}, {-3, 0}, {-3, 1}, {-2, -1}, {-2, 0}, {-2, 1}, {-1, 0} },
		[4] = { {-6, 2}, {-5, 2}, {-5, 3}, {-4, 2}, {-4, 3}, {-4, 4}, {-3, 2}, {-3, 3}, {-3, 4}, {-3, 5}, {-2, 2}, {-2, 3}, {-2, 4}, {-2, 5}, {-2, 6}, {-1, 1} },
		[5] = { {1, 1}, {2, 2}, {2, 3}, {2, 4}, {2, 5}, {2, 6}, {3, 2}, {3, 3}, {3, 4}, {3, 5}, {4, 2}, {4, 3}, {4, 4}, {5, 2}, {5, 3}, {6, 2} },
		[6] = { {-6, -2}, {-5, -3}, {-5, -2}, {-4, -4}, {-4, -3}, {-4, -2}, {-3, -5}, {-3, -4}, {-3, -3}, {-3, -2}, {-2, -6}, {-2, -5}, {-2, -4}, {-2, -3}, {-2, -2}, {-1, -1} },
		[7] = { {1, -1}, {2, -6}, {2, -5}, {2, -4}, {2, -3}, {2, -2}, {3, -5}, {3, -4}, {3, -3}, {3, -2}, {4, -4}, {4, -3}, {4, -2}, {5, -3}, {5, -2}, {6, -2} },
	},
	},
	exeta_amp_res = { kind = "target", shape = "chain", radius = 7 },
	utevo_res_ina = { kind = "self", shape = "single", radius = 0 },
	exana_kor = { kind = "self", shape = "single", radius = 0 },
	exana_flam = { kind = "self", shape = "single", radius = 0 },
	exana_mort = { kind = "self", shape = "single", radius = 0 },
	exana_vis = { kind = "self", shape = "single", radius = 0 },
	exana_pox = { kind = "self", shape = "single", radius = 0 },
	utori_mort = { kind = "target", shape = "single", radius = 0 },
	exevo_mort_ora = { kind = "target", shape = "square", radius = 2, tiles = { {-2, -2}, {-2, -1}, {-2, 0}, {-2, 1}, {-2, 2}, {-1, -2}, {-1, -1}, {-1, 0}, {-1, 1}, {-1, 2}, {0, -2}, {0, -1}, {0, 0}, {0, 1}, {0, 2}, {1, -2}, {1, -1}, {1, 0}, {1, 1}, {1, 2}, {2, -2}, {2, -1}, {2, 0}, {2, 1}, {2, 2} } },
	exori_mort = { kind = "target", shape = "single", radius = 0 },
	exori_gran_nia = { kind = "target", shape = "single", radius = 0 },
	exori_dir_san = { kind = "target", shape = "circle", radius = 2, tiles = { {-2, -1}, {-2, 0}, {-2, 1}, {-1, -2}, {-1, -1}, {-1, 0}, {-1, 1}, {-1, 2}, {0, -2}, {0, -1}, {0, 0}, {0, 1}, {0, 2}, {1, -2}, {1, -1}, {1, 0}, {1, 1}, {1, 2}, {2, -1}, {2, 0}, {2, 1} } },
	exevo_mas_san = { kind = "self", shape = "circle", radius = 3, tiles = { {-3, -1}, {-3, 0}, {-3, 1}, {-2, -2}, {-2, -1}, {-2, 0}, {-2, 1}, {-2, 2}, {-1, -3}, {-1, -2}, {-1, -1}, {-1, 0}, {-1, 1}, {-1, 2}, {-1, 3}, {0, -3}, {0, -2}, {0, -1}, {0, 0}, {0, 1}, {0, 2}, {0, 3}, {1, -3}, {1, -2}, {1, -1}, {1, 0}, {1, 1}, {1, 2}, {1, 3}, {2, -2}, {2, -1}, {2, 0}, {2, 1}, {2, 2}, {3, -1}, {3, 0}, {3, 1} } },
	exana_amp_res = { kind = "target", shape = "chain", radius = 7 },
	utori_hur = { kind = "self", shape = "single", radius = 0 },
	utevo_grav_san = { kind = "self", shape = "single", radius = 0 },
	exevo_tempo_mas_san = { kind = "target", shape = "circle", radius = 2, tiles = { {-2, -1}, {-2, 0}, {-2, 1}, {-1, -2}, {-1, -1}, {-1, 0}, {-1, 1}, {-1, 2}, {0, -2}, {0, -1}, {0, 0}, {0, 1}, {0, 2}, {1, -2}, {1, -1}, {1, 0}, {1, 1}, {1, 2}, {2, -1}, {2, 0}, {2, 1} } },
	exura_san = { kind = "self", shape = "single", radius = 0 },
	exori_san = { kind = "target", shape = "single", radius = 0 },
	exori_pug = { kind = "target", shape = "single", radius = 0 },
	utori_vis = { kind = "target", shape = "single", radius = 0 },
	utito_dru = { kind = "self", shape = "single", radius = 0 },
	utori_mas_sio = { kind = "self", shape = "circle", radius = 5, tiles = { {-5, 0}, {-4, -1}, {-4, 0}, {-4, 1}, {-3, -2}, {-3, -1}, {-3, 0}, {-3, 1}, {-3, 2}, {-2, -3}, {-2, -2}, {-2, -1}, {-2, 0}, {-2, 1}, {-2, 2}, {-2, 3}, {-1, -4}, {-1, -3}, {-1, -2}, {-1, -1}, {-1, 0}, {-1, 1}, {-1, 2}, {-1, 3}, {-1, 4}, {0, -5}, {0, -4}, {0, -3}, {0, -2}, {0, -1}, {0, 0}, {0, 1}, {0, 2}, {0, 3}, {0, 4}, {0, 5}, {1, -4}, {1, -3}, {1, -2}, {1, -1}, {1, 0}, {1, 1}, {1, 2}, {1, 3}, {1, 4}, {2, -3}, {2, -2}, {2, -1}, {2, 0}, {2, 1}, {2, 2}, {2, 3}, {3, -2}, {3, -1}, {3, 0}, {3, 1}, {3, 2}, {4, -1}, {4, 0}, {4, 1}, {5, 0} } },
	exevo_vis_lux = {
		kind = "direction",
		shape = "beam",
		radius = 0,
		wod = { check = "instantSkill", name = "Beam Mastery" },
		byDir = {
		[0] = { {0, -5}, {0, -4}, {0, -3}, {0, -2}, {0, -1} },
		[1] = { {1, 0}, {2, 0}, {3, 0}, {4, 0}, {5, 0} },
		[2] = { {0, 1}, {0, 2}, {0, 3}, {0, 4}, {0, 5} },
		[3] = { {-5, 0}, {-4, 0}, {-3, 0}, {-2, 0}, {-1, 0} },
		[4] = { {-5, 5}, {-4, 4}, {-3, 3}, {-2, 2}, {-1, 1} },
		[5] = { {1, 1}, {2, 2}, {3, 3}, {4, 4}, {5, 5} },
		[6] = { {-5, -5}, {-4, -4}, {-3, -3}, {-2, -2}, {-1, -1} },
		[7] = { {1, -1}, {2, -2}, {3, -3}, {4, -4}, {5, -5} },
	},
		-- Beam Mastery: AREA_BEAM7 center + full-length left/right flanks (incl. first sqm).
		wodByDir = {
		[0] = { {-1, -7}, {-1, -6}, {-1, -5}, {-1, -4}, {-1, -3}, {-1, -2}, {-1, -1}, {0, -7}, {0, -6}, {0, -5}, {0, -4}, {0, -3}, {0, -2}, {0, -1}, {1, -7}, {1, -6}, {1, -5}, {1, -4}, {1, -3}, {1, -2}, {1, -1} },
		[1] = { {1, -1}, {1, 0}, {1, 1}, {2, -1}, {2, 0}, {2, 1}, {3, -1}, {3, 0}, {3, 1}, {4, -1}, {4, 0}, {4, 1}, {5, -1}, {5, 0}, {5, 1}, {6, -1}, {6, 0}, {6, 1}, {7, -1}, {7, 0}, {7, 1} },
		[2] = { {-1, 1}, {-1, 2}, {-1, 3}, {-1, 4}, {-1, 5}, {-1, 6}, {-1, 7}, {0, 1}, {0, 2}, {0, 3}, {0, 4}, {0, 5}, {0, 6}, {0, 7}, {1, 1}, {1, 2}, {1, 3}, {1, 4}, {1, 5}, {1, 6}, {1, 7} },
		[3] = { {-7, -1}, {-7, 0}, {-7, 1}, {-6, -1}, {-6, 0}, {-6, 1}, {-5, -1}, {-5, 0}, {-5, 1}, {-4, -1}, {-4, 0}, {-4, 1}, {-3, -1}, {-3, 0}, {-3, 1}, {-2, -1}, {-2, 0}, {-2, 1}, {-1, -1}, {-1, 0}, {-1, 1} },
		[4] = { {-8, 6}, {-7, 5}, {-7, 7}, {-6, 4}, {-6, 6}, {-6, 8}, {-5, 3}, {-5, 5}, {-5, 7}, {-4, 2}, {-4, 4}, {-4, 6}, {-3, 1}, {-3, 3}, {-3, 5}, {-2, 0}, {-2, 2}, {-2, 4}, {-1, 1}, {-1, 3}, {0, 2} },
		[5] = { {0, 2}, {1, 1}, {1, 3}, {2, 0}, {2, 2}, {2, 4}, {3, 1}, {3, 3}, {3, 5}, {4, 2}, {4, 4}, {4, 6}, {5, 3}, {5, 5}, {5, 7}, {6, 4}, {6, 6}, {6, 8}, {7, 5}, {7, 7}, {8, 6} },
		[6] = { {-8, -6}, {-7, -7}, {-7, -5}, {-6, -8}, {-6, -6}, {-6, -4}, {-5, -7}, {-5, -5}, {-5, -3}, {-4, -6}, {-4, -4}, {-4, -2}, {-3, -5}, {-3, -3}, {-3, -1}, {-2, -4}, {-2, -2}, {-2, 0}, {-1, -3}, {-1, -1}, {0, -2} },
		[7] = { {0, -2}, {1, -3}, {1, -1}, {2, -4}, {2, -2}, {2, 0}, {3, -5}, {3, -3}, {3, -1}, {4, -6}, {4, -4}, {4, -2}, {5, -7}, {5, -5}, {5, -3}, {6, -8}, {6, -6}, {6, -4}, {7, -7}, {7, -5}, {8, -6} },
	},
	},
	exori_vis = { kind = "target", shape = "single", radius = 0 },
	exevo_vis_hur = {
		kind = "direction",
		shape = "squarewave",
		radius = 0,
		wod = { check = "additionalArea", name = "Energy Wave" },
		byDir = {
		[0] = { {-1, -5}, {-1, -4}, {-1, -3}, {0, -5}, {0, -4}, {0, -3}, {0, -2}, {0, -1}, {1, -5}, {1, -4}, {1, -3} },
		[1] = { {1, 0}, {2, 0}, {3, -1}, {3, 0}, {3, 1}, {4, -1}, {4, 0}, {4, 1}, {5, -1}, {5, 0}, {5, 1} },
		[2] = { {-1, 3}, {-1, 4}, {-1, 5}, {0, 1}, {0, 2}, {0, 3}, {0, 4}, {0, 5}, {1, 3}, {1, 4}, {1, 5} },
		[3] = { {-5, -1}, {-5, 0}, {-5, 1}, {-4, -1}, {-4, 0}, {-4, 1}, {-3, -1}, {-3, 0}, {-3, 1}, {-2, 0}, {-1, 0} },
		[4] = { {-5, 3}, {-5, 4}, {-5, 5}, {-4, 3}, {-4, 4}, {-4, 5}, {-3, 3}, {-3, 4}, {-3, 5}, {-2, 2}, {-1, 1} },
		[5] = { {1, 1}, {2, 2}, {3, 3}, {3, 4}, {3, 5}, {4, 3}, {4, 4}, {4, 5}, {5, 3}, {5, 4}, {5, 5} },
		[6] = { {-5, -5}, {-5, -4}, {-5, -3}, {-4, -5}, {-4, -4}, {-4, -3}, {-3, -5}, {-3, -4}, {-3, -3}, {-2, -2}, {-1, -1} },
		[7] = { {1, -1}, {2, -2}, {3, -5}, {3, -4}, {3, -3}, {4, -5}, {4, -4}, {4, -3}, {5, -5}, {5, -4}, {5, -3} },
	},
		wodByDir = {
		[0] = { {-2, -5}, {-2, -4}, {-1, -5}, {-1, -4}, {-1, -3}, {-1, -2}, {0, -5}, {0, -4}, {0, -3}, {0, -2}, {0, -1}, {1, -5}, {1, -4}, {1, -3}, {1, -2}, {2, -5}, {2, -4} },
		[1] = { {1, 0}, {2, -1}, {2, 0}, {2, 1}, {3, -1}, {3, 0}, {3, 1}, {4, -2}, {4, -1}, {4, 0}, {4, 1}, {4, 2}, {5, -2}, {5, -1}, {5, 0}, {5, 1}, {5, 2} },
		[2] = { {-2, 4}, {-2, 5}, {-1, 2}, {-1, 3}, {-1, 4}, {-1, 5}, {0, 1}, {0, 2}, {0, 3}, {0, 4}, {0, 5}, {1, 2}, {1, 3}, {1, 4}, {1, 5}, {2, 4}, {2, 5} },
		[3] = { {-5, -2}, {-5, -1}, {-5, 0}, {-5, 1}, {-5, 2}, {-4, -2}, {-4, -1}, {-4, 0}, {-4, 1}, {-4, 2}, {-3, -1}, {-3, 0}, {-3, 1}, {-2, -1}, {-2, 0}, {-2, 1}, {-1, 0} },
		[4] = { {-7, 2}, {-6, 2}, {-6, 3}, {-5, 2}, {-5, 3}, {-5, 4}, {-4, 2}, {-4, 3}, {-4, 4}, {-4, 5}, {-3, 2}, {-3, 3}, {-3, 4}, {-3, 5}, {-3, 6}, {-2, 2}, {-2, 3}, {-2, 4}, {-2, 5}, {-2, 6}, {-2, 7}, {-1, 1} },
		[5] = { {1, 1}, {2, 2}, {2, 3}, {2, 4}, {2, 5}, {2, 6}, {2, 7}, {3, 2}, {3, 3}, {3, 4}, {3, 5}, {3, 6}, {4, 2}, {4, 3}, {4, 4}, {4, 5}, {5, 2}, {5, 3}, {5, 4}, {6, 2}, {6, 3}, {7, 2} },
		[6] = { {-7, -2}, {-6, -3}, {-6, -2}, {-5, -4}, {-5, -3}, {-5, -2}, {-4, -5}, {-4, -4}, {-4, -3}, {-4, -2}, {-3, -6}, {-3, -5}, {-3, -4}, {-3, -3}, {-3, -2}, {-2, -7}, {-2, -6}, {-2, -5}, {-2, -4}, {-2, -3}, {-2, -2}, {-1, -1} },
		[7] = { {1, -1}, {2, -7}, {2, -6}, {2, -5}, {2, -4}, {2, -3}, {2, -2}, {3, -6}, {3, -5}, {3, -4}, {3, -3}, {3, -2}, {4, -5}, {4, -4}, {4, -3}, {4, -2}, {5, -4}, {5, -3}, {5, -2}, {6, -3}, {6, -2}, {7, -2} },
	},
	},
	utevo_mas_sio = { kind = "self", shape = "single", radius = 0 },
	utori_pox = { kind = "target", shape = "single", radius = 0 },
	exevo_gran_mas_frigo = { kind = "self", shape = "circle", radius = 5, tiles = { {-5, 0}, {-4, -1}, {-4, 0}, {-4, 1}, {-3, -2}, {-3, -1}, {-3, 0}, {-3, 1}, {-3, 2}, {-2, -3}, {-2, -2}, {-2, -1}, {-2, 0}, {-2, 1}, {-2, 2}, {-2, 3}, {-1, -4}, {-1, -3}, {-1, -2}, {-1, -1}, {-1, 0}, {-1, 1}, {-1, 2}, {-1, 3}, {-1, 4}, {0, -5}, {0, -4}, {0, -3}, {0, -2}, {0, -1}, {0, 0}, {0, 1}, {0, 2}, {0, 3}, {0, 4}, {0, 5}, {1, -4}, {1, -3}, {1, -2}, {1, -1}, {1, 0}, {1, 1}, {1, 2}, {1, 3}, {1, 4}, {2, -3}, {2, -2}, {2, -1}, {2, 0}, {2, 1}, {2, 2}, {2, 3}, {3, -2}, {3, -1}, {3, 0}, {3, 1}, {3, 2}, {4, -1}, {4, 0}, {4, 1}, {5, 0} } },
	exori_dir_moe = { kind = "target", shape = "circle", radius = 2, tiles = { {-2, -1}, {-2, 0}, {-2, 1}, {-1, -2}, {-1, -1}, {-1, 0}, {-1, 1}, {-1, 2}, {0, -2}, {0, -1}, {0, 0}, {0, 1}, {0, 2}, {1, -2}, {1, -1}, {1, 0}, {1, 1}, {1, 2}, {2, -1}, {2, 0}, {2, 1} } },
	exori_con = { kind = "target", shape = "single", radius = 0 },
	exori_amp_kor = { kind = "target", shape = "single", radius = 0 },
	exori_moe = { kind = "self", shape = "circle", radius = 3, tiles = { {-3, -1}, {-3, 0}, {-3, 1}, {-2, -2}, {-2, -1}, {-2, 0}, {-2, 1}, {-2, 2}, {-1, -3}, {-1, -2}, {-1, -1}, {-1, 0}, {-1, 1}, {-1, 2}, {-1, 3}, {0, -3}, {0, -2}, {0, -1}, {0, 0}, {0, 1}, {0, 2}, {0, 3}, {1, -3}, {1, -2}, {1, -1}, {1, 0}, {1, 1}, {1, 2}, {1, 3}, {2, -2}, {2, -1}, {2, 0}, {2, 1}, {2, 2}, {3, -1}, {3, 0}, {3, 1} } },
	exura_med_ico = { kind = "self", shape = "single", radius = 0 },
	exori_gran = { kind = "self", shape = "square", radius = 1, tiles = { {-1, -1}, {-1, 0}, {-1, 1}, {0, -1}, {0, 0}, {0, 1}, {1, -1}, {1, 0}, {1, 1} } },
	exevo_flam_hur = {
		kind = "direction",
		shape = "wave",
		radius = 0,
		byDir = {
		[0] = { {-2, -4}, {-1, -4}, {-1, -3}, {-1, -2}, {0, -4}, {0, -3}, {0, -2}, {0, -1}, {1, -4}, {1, -3}, {1, -2}, {2, -4} },
		[1] = { {1, 0}, {2, -1}, {2, 0}, {2, 1}, {3, -1}, {3, 0}, {3, 1}, {4, -2}, {4, -1}, {4, 0}, {4, 1}, {4, 2} },
		[2] = { {-2, 4}, {-1, 2}, {-1, 3}, {-1, 4}, {0, 1}, {0, 2}, {0, 3}, {0, 4}, {1, 2}, {1, 3}, {1, 4}, {2, 4} },
		[3] = { {-4, -2}, {-4, -1}, {-4, 0}, {-4, 1}, {-4, 2}, {-3, -1}, {-3, 0}, {-3, 1}, {-2, -1}, {-2, 0}, {-2, 1}, {-1, 0} },
		[4] = { {-6, 2}, {-5, 2}, {-5, 3}, {-4, 2}, {-4, 3}, {-4, 4}, {-3, 2}, {-3, 3}, {-3, 4}, {-3, 5}, {-2, 2}, {-2, 3}, {-2, 4}, {-2, 5}, {-2, 6}, {-1, 1} },
		[5] = { {1, 1}, {2, 2}, {2, 3}, {2, 4}, {2, 5}, {2, 6}, {3, 2}, {3, 3}, {3, 4}, {3, 5}, {4, 2}, {4, 3}, {4, 4}, {5, 2}, {5, 3}, {6, 2} },
		[6] = { {-6, -2}, {-5, -3}, {-5, -2}, {-4, -4}, {-4, -3}, {-4, -2}, {-3, -5}, {-3, -4}, {-3, -3}, {-3, -2}, {-2, -6}, {-2, -5}, {-2, -4}, {-2, -3}, {-2, -2}, {-1, -1} },
		[7] = { {1, -1}, {2, -6}, {2, -5}, {2, -4}, {2, -3}, {2, -2}, {3, -5}, {3, -4}, {3, -3}, {3, -2}, {4, -4}, {4, -3}, {4, -2}, {5, -3}, {5, -2}, {6, -2} },
	},
	},
	exori_flam = { kind = "target", shape = "single", radius = 0 },
	exori_mas_pug = {
		kind = "direction",
		shape = "wave",
		radius = 0,
		wod = { check = "additionalArea", name = "Flurry of Blows" },
		byDir = {
		[0] = { {-1, -2}, {-1, -1}, {-1, 0}, {0, -3}, {0, -2}, {0, -1}, {1, -2}, {1, -1}, {1, 0} },
		[1] = { {0, -1}, {0, 1}, {1, -1}, {1, 0}, {1, 1}, {2, -1}, {2, 0}, {2, 1}, {3, 0} },
		[2] = { {-1, 0}, {-1, 1}, {-1, 2}, {0, 1}, {0, 2}, {0, 3}, {1, 0}, {1, 1}, {1, 2} },
		[3] = { {-3, 0}, {-2, -1}, {-2, 0}, {-2, 1}, {-1, -1}, {-1, 0}, {-1, 1}, {0, -1}, {0, 1} },
	},
		wodByDir = {
		[0] = { {-2, -2}, {-2, -1}, {-2, 0}, {-1, -3}, {-1, -2}, {-1, -1}, {-1, 0}, {0, -4}, {0, -3}, {0, -2}, {0, -1}, {1, -3}, {1, -2}, {1, -1}, {1, 0}, {2, -2}, {2, -1}, {2, 0} },
		[1] = { {0, -2}, {0, -1}, {0, 1}, {0, 2}, {1, -2}, {1, -1}, {1, 0}, {1, 1}, {1, 2}, {2, -2}, {2, -1}, {2, 0}, {2, 1}, {2, 2}, {3, -1}, {3, 0}, {3, 1}, {4, 0} },
		[2] = { {-2, 0}, {-2, 1}, {-2, 2}, {-1, 0}, {-1, 1}, {-1, 2}, {-1, 3}, {0, 1}, {0, 2}, {0, 3}, {0, 4}, {1, 0}, {1, 1}, {1, 2}, {1, 3}, {2, 0}, {2, 1}, {2, 2} },
		[3] = { {-4, 0}, {-3, -1}, {-3, 0}, {-3, 1}, {-2, -2}, {-2, -1}, {-2, 0}, {-2, 1}, {-2, 2}, {-1, -2}, {-1, -1}, {-1, 0}, {-1, 1}, {-1, 2}, {0, -2}, {0, -1}, {0, 1}, {0, 2} },
	},
	},
	utevo_nia = { kind = "self", shape = "single", radius = 0 },
	utamo_tio = { kind = "self", shape = "single", radius = 0 },
	exevo_pan = { kind = "self", shape = "single", radius = 0 },
	exori_gran_pug = { kind = "target", shape = "single", radius = 0 },
	exevo_fur_frigo = { kind = "target", shape = "chain", radius = 5 },
	exevo_fur_tera = { kind = "target", shape = "chain", radius = 5 },
	exori_min = {
		kind = "direction",
		shape = "wave",
		radius = 0,
		wod = { check = "additionalArea", name = "Front Sweep" },
		byDir = {
		[0] = { {-1, -1}, {0, -1}, {1, -1} },
		[1] = { {1, -1}, {1, 0}, {1, 1} },
		[2] = { {-1, 1}, {0, 1}, {1, 1} },
		[3] = { {-1, -1}, {-1, 0}, {-1, 1} },
		[4] = { {-2, 0}, {-1, 1}, {0, 2} },
		[5] = { {0, 2}, {1, 1}, {2, 0} },
		[6] = { {-2, 0}, {-1, -1}, {0, -2} },
		[7] = { {0, -2}, {1, -1}, {2, 0} },
	},
		wodByDir = {
		[0] = { {-1, -1}, {-1, 0}, {0, -1}, {1, -1}, {1, 0} },
		[1] = { {0, -1}, {0, 1}, {1, -1}, {1, 0}, {1, 1} },
		[2] = { {-1, 0}, {-1, 1}, {0, 1}, {1, 0}, {1, 1} },
		[3] = { {-1, -1}, {-1, 0}, {-1, 1}, {0, -1}, {0, 1} },
		[4] = { {-3, -1}, {-2, 0}, {-1, 1}, {0, 2}, {1, 3} },
		[5] = { {-1, 3}, {0, 2}, {1, 1}, {2, 0}, {3, -1} },
		[6] = { {-3, 1}, {-2, 0}, {-1, -1}, {0, -2}, {1, -3} },
		[7] = { {-1, -3}, {0, -2}, {1, -1}, {2, 0}, {3, 1} },
	},
	},
	exevo_max_mort = {
		kind = "direction",
		shape = "beam",
		radius = 0,
		byDir = {
		[0] = { {0, -8}, {0, -7}, {0, -6}, {0, -5}, {0, -4}, {0, -3}, {0, -2}, {0, -1} },
		[1] = { {1, 0}, {2, 0}, {3, 0}, {4, 0}, {5, 0}, {6, 0}, {7, 0}, {8, 0} },
		[2] = { {0, 1}, {0, 2}, {0, 3}, {0, 4}, {0, 5}, {0, 6}, {0, 7}, {0, 8} },
		[3] = { {-8, 0}, {-7, 0}, {-6, 0}, {-5, 0}, {-4, 0}, {-3, 0}, {-2, 0}, {-1, 0} },
	},
	},
	exevo_gran_vis_lux = {
		kind = "direction",
		shape = "beam",
		radius = 0,
		byDir = {
		[0] = { {0, -8}, {0, -7}, {0, -6}, {0, -5}, {0, -4}, {0, -3}, {0, -2}, {0, -1} },
		[1] = { {1, 0}, {2, 0}, {3, 0}, {4, 0}, {5, 0}, {6, 0}, {7, 0}, {8, 0} },
		[2] = { {0, 1}, {0, 2}, {0, 3}, {0, 4}, {0, 5}, {0, 6}, {0, 7}, {0, 8} },
		[3] = { {-8, 0}, {-7, 0}, {-6, 0}, {-5, 0}, {-4, 0}, {-3, 0}, {-2, 0}, {-1, 0} },
	},
	},
	exevo_gran_flam_hur = {
		kind = "direction",
		shape = "wave",
		radius = 0,
		byDir = {
		[0] = { {-2, -5}, {-2, -4}, {-1, -5}, {-1, -4}, {-1, -3}, {-1, -2}, {0, -5}, {0, -4}, {0, -3}, {0, -2}, {0, -1}, {1, -5}, {1, -4}, {1, -3}, {1, -2}, {2, -5}, {2, -4} },
		[1] = { {1, 0}, {2, -1}, {2, 0}, {2, 1}, {3, -1}, {3, 0}, {3, 1}, {4, -2}, {4, -1}, {4, 0}, {4, 1}, {4, 2}, {5, -2}, {5, -1}, {5, 0}, {5, 1}, {5, 2} },
		[2] = { {-2, 4}, {-2, 5}, {-1, 2}, {-1, 3}, {-1, 4}, {-1, 5}, {0, 1}, {0, 2}, {0, 3}, {0, 4}, {0, 5}, {1, 2}, {1, 3}, {1, 4}, {1, 5}, {2, 4}, {2, 5} },
		[3] = { {-5, -2}, {-5, -1}, {-5, 0}, {-5, 1}, {-5, 2}, {-4, -2}, {-4, -1}, {-4, 0}, {-4, 1}, {-4, 2}, {-3, -1}, {-3, 0}, {-3, 1}, {-2, -1}, {-2, 0}, {-2, 1}, {-1, 0} },
		[4] = { {-7, 2}, {-6, 2}, {-6, 3}, {-5, 2}, {-5, 3}, {-5, 4}, {-4, 2}, {-4, 3}, {-4, 4}, {-4, 5}, {-3, 2}, {-3, 3}, {-3, 4}, {-3, 5}, {-3, 6}, {-2, 2}, {-2, 3}, {-2, 4}, {-2, 5}, {-2, 6}, {-2, 7}, {-1, 1} },
		[5] = { {1, 1}, {2, 2}, {2, 3}, {2, 4}, {2, 5}, {2, 6}, {2, 7}, {3, 2}, {3, 3}, {3, 4}, {3, 5}, {3, 6}, {4, 2}, {4, 3}, {4, 4}, {4, 5}, {5, 2}, {5, 3}, {5, 4}, {6, 2}, {6, 3}, {7, 2} },
		[6] = { {-7, -2}, {-6, -3}, {-6, -2}, {-5, -4}, {-5, -3}, {-5, -2}, {-4, -5}, {-4, -4}, {-4, -3}, {-4, -2}, {-3, -6}, {-3, -5}, {-3, -4}, {-3, -3}, {-3, -2}, {-2, -7}, {-2, -6}, {-2, -5}, {-2, -4}, {-2, -3}, {-2, -2}, {-1, -1} },
		[7] = { {1, -1}, {2, -7}, {2, -6}, {2, -5}, {2, -4}, {2, -3}, {2, -2}, {3, -6}, {3, -5}, {3, -4}, {3, -3}, {3, -2}, {4, -5}, {4, -4}, {4, -3}, {4, -2}, {5, -4}, {5, -3}, {5, -2}, {6, -3}, {6, -2}, {7, -2} },
	},
	},
	exori_gran_mas_pug = {
		kind = "direction",
		shape = "wave",
		radius = 0,
		byDir = {
		[0] = { {-2, -1}, {-1, -3}, {-1, -2}, {-1, -1}, {-1, 0}, {0, -4}, {0, -3}, {0, -2}, {0, -1}, {1, -3}, {1, -2}, {1, -1}, {1, 0}, {2, -1} },
		[1] = { {0, -1}, {0, 1}, {1, -2}, {1, -1}, {1, 0}, {1, 1}, {1, 2}, {2, -1}, {2, 0}, {2, 1}, {3, -1}, {3, 0}, {3, 1}, {4, 0} },
		[2] = { {-2, 1}, {-1, 0}, {-1, 1}, {-1, 2}, {-1, 3}, {0, 1}, {0, 2}, {0, 3}, {0, 4}, {1, 0}, {1, 1}, {1, 2}, {1, 3}, {2, 1} },
		[3] = { {-4, 0}, {-3, -1}, {-3, 0}, {-3, 1}, {-2, -1}, {-2, 0}, {-2, 1}, {-1, -2}, {-1, -1}, {-1, 0}, {-1, 1}, {-1, 2}, {0, -1}, {0, 1} },
	},
	},
	exori_nia = { kind = "target", shape = "single", radius = 0 },
	exori_mas = { kind = "self", shape = "circle", radius = 3, tiles = { {-3, -1}, {-3, 0}, {-3, 1}, {-2, -2}, {-2, -1}, {-2, 0}, {-2, 1}, {-2, 2}, {-1, -3}, {-1, -2}, {-1, -1}, {-1, 0}, {-1, 1}, {-1, 2}, {-1, 3}, {0, -3}, {0, -2}, {0, -1}, {0, 0}, {0, 1}, {0, 2}, {0, 3}, {1, -3}, {1, -2}, {1, -1}, {1, 0}, {1, 1}, {1, 2}, {1, 3}, {2, -2}, {2, -1}, {2, 0}, {2, 1}, {2, 2}, {3, -1}, {3, 0}, {3, 1} } },
	utani_hur = { kind = "self", shape = "single", radius = 0 },
	exura_sio = { kind = "friend", shape = "single", radius = 0 },
	utura_mas_sio = { kind = "self", shape = "circle", radius = 5, tiles = { {-5, 0}, {-4, -1}, {-4, 0}, {-4, 1}, {-3, -2}, {-3, -1}, {-3, 0}, {-3, 1}, {-3, 2}, {-2, -3}, {-2, -2}, {-2, -1}, {-2, 0}, {-2, 1}, {-2, 2}, {-2, 3}, {-1, -4}, {-1, -3}, {-1, -2}, {-1, -1}, {-1, 0}, {-1, 1}, {-1, 2}, {-1, 3}, {-1, 4}, {0, -5}, {0, -4}, {0, -3}, {0, -2}, {0, -1}, {0, 0}, {0, 1}, {0, 2}, {0, 3}, {0, 4}, {0, 5}, {1, -4}, {1, -3}, {1, -2}, {1, -1}, {1, 0}, {1, 1}, {1, 2}, {1, 3}, {1, 4}, {2, -3}, {2, -2}, {2, -1}, {2, 0}, {2, 1}, {2, 2}, {2, 3}, {3, -2}, {3, -1}, {3, 0}, {3, 1}, {3, 2}, {4, -1}, {4, 0}, {4, 1}, {5, 0} } },
	exevo_gran_mas_flam = { kind = "self", shape = "circle", radius = 5, tiles = { {-5, 0}, {-4, -1}, {-4, 0}, {-4, 1}, {-3, -2}, {-3, -1}, {-3, 0}, {-3, 1}, {-3, 2}, {-2, -3}, {-2, -2}, {-2, -1}, {-2, 0}, {-2, 1}, {-2, 2}, {-2, 3}, {-1, -4}, {-1, -3}, {-1, -2}, {-1, -1}, {-1, 0}, {-1, 1}, {-1, 2}, {-1, 3}, {-1, 4}, {0, -5}, {0, -4}, {0, -3}, {0, -2}, {0, -1}, {0, 0}, {0, 1}, {0, 2}, {0, 3}, {0, 4}, {0, 5}, {1, -4}, {1, -3}, {1, -2}, {1, -1}, {1, 0}, {1, 1}, {1, 2}, {1, 3}, {1, 4}, {2, -3}, {2, -2}, {2, -1}, {2, 0}, {2, 1}, {2, 2}, {2, 3}, {3, -2}, {3, -1}, {3, 0}, {3, 1}, {3, 2}, {4, -1}, {4, 0}, {4, 1}, {5, 0} } },
	utori_san = { kind = "target", shape = "single", radius = 0 },
	exevo_ulus_frigo = { kind = "self", shape = "single", radius = 3, tiles = { {-4, -1}, {-4, 0}, {-4, 1}, {-3, -2}, {-3, -1}, {-3, 0}, {-3, 1}, {-3, 2}, {-2, -3}, {-2, -2}, {-2, -1}, {-2, 0}, {-2, 1}, {-2, 2}, {-2, 3}, {-1, -4}, {-1, -3}, {-1, -2}, {-1, 2}, {-1, 3}, {-1, 4}, {0, -4}, {0, -3}, {0, -2}, {0, 2}, {0, 3}, {0, 4}, {1, -4}, {1, -3}, {1, -2}, {1, 2}, {1, 3}, {1, 4}, {2, -3}, {2, -2}, {2, -1}, {2, 0}, {2, 1}, {2, 2}, {2, 3}, {3, -2}, {3, -1}, {3, 0}, {3, 1}, {3, 2}, {4, -1}, {4, 0}, {4, 1} } },
	exori_frigo = { kind = "target", shape = "single", radius = 0 },
	exevo_frigo_hur = {
		kind = "direction",
		shape = "wave",
		radius = 0,
		byDir = {
		[0] = { {-2, -4}, {-1, -4}, {-1, -3}, {-1, -2}, {0, -4}, {0, -3}, {0, -2}, {0, -1}, {1, -4}, {1, -3}, {1, -2}, {2, -4} },
		[1] = { {1, 0}, {2, -1}, {2, 0}, {2, 1}, {3, -1}, {3, 0}, {3, 1}, {4, -2}, {4, -1}, {4, 0}, {4, 1}, {4, 2} },
		[2] = { {-2, 4}, {-1, 2}, {-1, 3}, {-1, 4}, {0, 1}, {0, 2}, {0, 3}, {0, 4}, {1, 2}, {1, 3}, {1, 4}, {2, 4} },
		[3] = { {-4, -2}, {-4, -1}, {-4, 0}, {-4, 1}, {-4, 2}, {-3, -1}, {-3, 0}, {-3, 1}, {-2, -1}, {-2, 0}, {-2, 1}, {-1, 0} },
		[4] = { {-6, 2}, {-5, 2}, {-5, 3}, {-4, 2}, {-4, 3}, {-4, 4}, {-3, 2}, {-3, 3}, {-3, 4}, {-3, 5}, {-2, 2}, {-2, 3}, {-2, 4}, {-2, 5}, {-2, 6}, {-1, 1} },
		[5] = { {1, 1}, {2, 2}, {2, 3}, {2, 4}, {2, 5}, {2, 6}, {3, 2}, {3, 3}, {3, 4}, {3, 5}, {4, 2}, {4, 3}, {4, 4}, {5, 2}, {5, 3}, {6, 2} },
		[6] = { {-6, -2}, {-5, -3}, {-5, -2}, {-4, -4}, {-4, -3}, {-4, -2}, {-3, -5}, {-3, -4}, {-3, -3}, {-3, -2}, {-2, -6}, {-2, -5}, {-2, -4}, {-2, -3}, {-2, -2}, {-1, -1} },
		[7] = { {1, -1}, {2, -6}, {2, -5}, {2, -4}, {2, -3}, {2, -2}, {3, -5}, {3, -4}, {3, -3}, {3, -2}, {4, -4}, {4, -3}, {4, -2}, {5, -3}, {5, -2}, {6, -2} },
	},
	},
	utori_flam = { kind = "target", shape = "single", radius = 0 },
	utori_kor = { kind = "target", shape = "single", radius = 0 },
	exura_gran = { kind = "self", shape = "single", radius = 0 },
	utura_gran = { kind = "self", shape = "single", radius = 0 },
	exura_gran_ico = { kind = "self", shape = "single", radius = 0 },
	utana_vid = { kind = "self", shape = "single", radius = 0 },
	exori_infir_con = { kind = "target", shape = "single", radius = 0 },
	exori_infir_min = {
		kind = "direction",
		shape = "wave",
		radius = 0,
		byDir = {
		[0] = { {-1, -1}, {0, -1}, {1, -1} },
		[1] = { {1, -1}, {1, 0}, {1, 1} },
		[2] = { {-1, 1}, {0, 1}, {1, 1} },
		[3] = { {-1, -1}, {-1, 0}, {-1, 1} },
		[4] = { {-2, 0}, {-1, 1}, {0, 2} },
		[5] = { {0, 2}, {1, 1}, {2, 0} },
		[6] = { {-2, 0}, {-1, -1}, {0, -2} },
		[7] = { {0, -2}, {1, -1}, {2, 0} },
	},
	},
	exani_hur = { kind = "self", shape = "single", radius = 0 },
	exura = { kind = "self", shape = "single", radius = 0 },
	exori_amp_vis = { kind = "target", shape = "single", radius = 0 },
	exura_infir = { kind = "self", shape = "single", radius = 0 },
	utamo_vita = { kind = "self", shape = "single", radius = 0 },
	exura_gran_mas_res = { kind = "self", shape = "circle", radius = 3, wod = { check = "additionalArea", name = "Mass Healing" }, tiles = { {-3, -1}, {-3, 0}, {-3, 1}, {-2, -2}, {-2, -1}, {-2, 0}, {-2, 1}, {-2, 2}, {-1, -3}, {-1, -2}, {-1, -1}, {-1, 0}, {-1, 1}, {-1, 2}, {-1, 3}, {0, -3}, {0, -2}, {0, -1}, {0, 0}, {0, 1}, {0, 2}, {0, 3}, {1, -3}, {1, -2}, {1, -1}, {1, 0}, {1, 1}, {1, 2}, {1, 3}, {2, -2}, {2, -1}, {2, 0}, {2, 1}, {2, 2}, {3, -1}, {3, 0}, {3, 1} }, wodTiles = { {-4, -1}, {-4, 0}, {-4, 1}, {-3, -2}, {-3, -1}, {-3, 0}, {-3, 1}, {-3, 2}, {-2, -3}, {-2, -2}, {-2, -1}, {-2, 0}, {-2, 1}, {-2, 2}, {-2, 3}, {-1, -4}, {-1, -3}, {-1, -2}, {-1, -1}, {-1, 0}, {-1, 1}, {-1, 2}, {-1, 3}, {-1, 4}, {0, -4}, {0, -3}, {0, -2}, {0, -1}, {0, 0}, {0, 1}, {0, 2}, {0, 3}, {0, 4}, {1, -4}, {1, -3}, {1, -2}, {1, -1}, {1, 0}, {1, 1}, {1, 2}, {1, 3}, {1, 4}, {2, -3}, {2, -2}, {2, -1}, {2, 0}, {2, 1}, {2, 2}, {2, 3}, {3, -2}, {3, -1}, {3, 0}, {3, 1}, {3, 2}, {4, -1}, {4, 0}, {4, 1} }, wodRadius = 4 },
	exura_mas_nia = { kind = "self", shape = "circle", radius = 4, tiles = { {-4, -1}, {-4, 0}, {-4, 1}, {-3, -2}, {-3, -1}, {-3, 0}, {-3, 1}, {-3, 2}, {-2, -3}, {-2, -2}, {-2, -1}, {-2, 0}, {-2, 1}, {-2, 2}, {-2, 3}, {-1, -4}, {-1, -3}, {-1, -2}, {-1, -1}, {-1, 0}, {-1, 1}, {-1, 2}, {-1, 3}, {-1, 4}, {0, -4}, {0, -3}, {0, -2}, {0, -1}, {0, 0}, {0, 1}, {0, 2}, {0, 3}, {0, 4}, {1, -4}, {1, -3}, {1, -2}, {1, -1}, {1, 0}, {1, 1}, {1, 2}, {1, 3}, {1, 4}, {2, -3}, {2, -2}, {2, -1}, {2, 0}, {2, 1}, {2, 2}, {2, 3}, {3, -2}, {3, -1}, {3, 0}, {3, 1}, {3, 2}, {4, -1}, {4, 0}, {4, 1} } },
	uteta_mort = { kind = "self", shape = "single", radius = 0 },
	uteta_flam = { kind = "self", shape = "single", radius = 0 },
	uteta_vis = { kind = "self", shape = "single", radius = 0 },
	utevo_gran_res_tio = { kind = "self", shape = "single", radius = 0 },
	exori_infir_tera = { kind = "target", shape = "single", radius = 0 },
	exori_amp_pug = { kind = "target", shape = "single", radius = 0 },
	exura_gran_sio = { kind = "friend", shape = "single", radius = 0 },
	exori_moe_ico = { kind = "target", shape = "single", radius = 0 },
	utamo_mas_sio = { kind = "self", shape = "circle", radius = 5, tiles = { {-5, 0}, {-4, -1}, {-4, 0}, {-4, 1}, {-3, -2}, {-3, -1}, {-3, 0}, {-3, 1}, {-3, 2}, {-2, -3}, {-2, -2}, {-2, -1}, {-2, 0}, {-2, 1}, {-2, 2}, {-2, 3}, {-1, -4}, {-1, -3}, {-1, -2}, {-1, -1}, {-1, 0}, {-1, 1}, {-1, 2}, {-1, 3}, {-1, 4}, {0, -5}, {0, -4}, {0, -3}, {0, -2}, {0, -1}, {0, 0}, {0, 1}, {0, 2}, {0, 3}, {0, 4}, {0, 5}, {1, -4}, {1, -3}, {1, -2}, {1, -1}, {1, 0}, {1, 1}, {1, 2}, {1, 3}, {1, 4}, {2, -3}, {2, -2}, {2, -1}, {2, 0}, {2, 1}, {2, 2}, {2, 3}, {3, -2}, {3, -1}, {3, 0}, {3, 1}, {3, 2}, {4, -1}, {4, 0}, {4, 1}, {5, 0} } },
	utamo_tempo = { kind = "self", shape = "single", radius = 0 },
	exevo_gran_mas_vis = { kind = "self", shape = "circle", radius = 6, tiles = { {-6, 0}, {-5, -1}, {-5, 0}, {-5, 1}, {-4, -2}, {-4, -1}, {-4, 0}, {-4, 1}, {-4, 2}, {-3, -3}, {-3, -2}, {-3, -1}, {-3, 0}, {-3, 1}, {-3, 2}, {-3, 3}, {-2, -4}, {-2, -3}, {-2, -2}, {-2, -1}, {-2, 0}, {-2, 1}, {-2, 2}, {-2, 3}, {-2, 4}, {-1, -5}, {-1, -4}, {-1, -3}, {-1, -2}, {-1, -1}, {-1, 0}, {-1, 1}, {-1, 2}, {-1, 3}, {-1, 4}, {-1, 5}, {0, -6}, {0, -5}, {0, -4}, {0, -3}, {0, -2}, {0, -1}, {0, 0}, {0, 1}, {0, 2}, {0, 3}, {0, 4}, {0, 5}, {0, 6}, {1, -5}, {1, -4}, {1, -3}, {1, -2}, {1, -1}, {1, 0}, {1, 1}, {1, 2}, {1, 3}, {1, 4}, {1, 5}, {2, -4}, {2, -3}, {2, -2}, {2, -1}, {2, 0}, {2, 1}, {2, 2}, {2, 3}, {2, 4}, {3, -3}, {3, -2}, {3, -1}, {3, 0}, {3, 1}, {3, 2}, {3, 3}, {4, -2}, {4, -1}, {4, 0}, {4, 1}, {4, 2}, {5, -1}, {5, 0}, {5, 1}, {6, 0} } },
	utura = { kind = "self", shape = "single", radius = 0 },
	exura_max_vita = { kind = "self", shape = "single", radius = 0 },
	exura_tio_sio = { kind = "friend", shape = "single", radius = 0 },
	exura_gran_san = { kind = "self", shape = "single", radius = 0 },
	exori_kor = { kind = "self", shape = "circle", radius = 3, wod = { check = "additionalArea", name = "Sap Strength" }, tiles = { {-3, -1}, {-3, 0}, {-3, 1}, {-2, -2}, {-2, -1}, {-2, 0}, {-2, 1}, {-2, 2}, {-1, -3}, {-1, -2}, {-1, -1}, {-1, 0}, {-1, 1}, {-1, 2}, {-1, 3}, {0, -3}, {0, -2}, {0, -1}, {0, 0}, {0, 1}, {0, 2}, {0, 3}, {1, -3}, {1, -2}, {1, -1}, {1, 0}, {1, 1}, {1, 2}, {1, 3}, {2, -2}, {2, -1}, {2, 0}, {2, 1}, {2, 2}, {3, -1}, {3, 0}, {3, 1} }, wodTiles = { {-5, 0}, {-4, -1}, {-4, 0}, {-4, 1}, {-3, -2}, {-3, -1}, {-3, 0}, {-3, 1}, {-3, 2}, {-2, -3}, {-2, -2}, {-2, -1}, {-2, 0}, {-2, 1}, {-2, 2}, {-2, 3}, {-1, -4}, {-1, -3}, {-1, -2}, {-1, -1}, {-1, 0}, {-1, 1}, {-1, 2}, {-1, 3}, {-1, 4}, {0, -5}, {0, -4}, {0, -3}, {0, -2}, {0, -1}, {0, 0}, {0, 1}, {0, 2}, {0, 3}, {0, 4}, {0, 5}, {1, -4}, {1, -3}, {1, -2}, {1, -1}, {1, 0}, {1, 1}, {1, 2}, {1, 3}, {1, 4}, {2, -3}, {2, -2}, {2, -1}, {2, 0}, {2, 1}, {2, 2}, {2, 3}, {3, -2}, {3, -1}, {3, 0}, {3, 1}, {3, 2}, {4, -1}, {4, 0}, {4, 1}, {5, 0} }, wodRadius = 5 },
	exevo_infir_flam_hur = {
		kind = "direction",
		shape = "wave",
		radius = 0,
		byDir = {
		[0] = { {-2, -4}, {-1, -4}, {-1, -3}, {-1, -2}, {0, -4}, {0, -3}, {0, -2}, {0, -1}, {1, -4}, {1, -3}, {1, -2}, {2, -4} },
		[1] = { {1, 0}, {2, -1}, {2, 0}, {2, 1}, {3, -1}, {3, 0}, {3, 1}, {4, -2}, {4, -1}, {4, 0}, {4, 1}, {4, 2} },
		[2] = { {-2, 4}, {-1, 2}, {-1, 3}, {-1, 4}, {0, 1}, {0, 2}, {0, 3}, {0, 4}, {1, 2}, {1, 3}, {1, 4}, {2, 4} },
		[3] = { {-4, -2}, {-4, -1}, {-4, 0}, {-4, 1}, {-4, 2}, {-3, -1}, {-3, 0}, {-3, 1}, {-2, -1}, {-2, 0}, {-2, 1}, {-1, 0} },
		[4] = { {-6, 2}, {-5, 2}, {-5, 3}, {-4, 2}, {-4, 3}, {-4, 4}, {-3, 2}, {-3, 3}, {-3, 4}, {-3, 5}, {-2, 2}, {-2, 3}, {-2, 4}, {-2, 5}, {-2, 6}, {-1, 1} },
		[5] = { {1, 1}, {2, 2}, {2, 3}, {2, 4}, {2, 5}, {2, 6}, {3, 2}, {3, 3}, {3, 4}, {3, 5}, {4, 2}, {4, 3}, {4, 4}, {5, 2}, {5, 3}, {6, 2} },
		[6] = { {-6, -2}, {-5, -3}, {-5, -2}, {-4, -4}, {-4, -3}, {-4, -2}, {-3, -5}, {-3, -4}, {-3, -3}, {-3, -2}, {-2, -6}, {-2, -5}, {-2, -4}, {-2, -3}, {-2, -2}, {-1, -1} },
		[7] = { {1, -1}, {2, -6}, {2, -5}, {2, -4}, {2, -3}, {2, -2}, {3, -5}, {3, -4}, {3, -3}, {3, -2}, {4, -4}, {4, -3}, {4, -2}, {5, -3}, {5, -2}, {6, -2} },
	},
	},
	utura_sio = { kind = "self", shape = "single", radius = 0 },
	utori_con = { kind = "self", shape = "single", radius = 0 },
	exori_ico_scu = { kind = "target", shape = "square", radius = 1, tiles = { {-1, -1}, {-1, 0}, {-1, 1}, {0, -1}, {0, 0}, {0, 1}, {1, -1}, {1, 0}, {1, 1} } },
	exori_scu = { kind = "self", shape = "square", radius = 1, tiles = { {-1, -1}, {-1, 0}, {-1, 1}, {0, -1}, {0, 0}, {0, 1}, {1, -1}, {1, 0}, {1, 1} } },
	exura_gran_tio = { kind = "self", shape = "single", radius = 0 },
	exori_gran_mas_nia = { kind = "self", shape = "single", radius = 0 },
	exori_gran_vis = { kind = "target", shape = "single", radius = 0 },
	exori_gran_con = { kind = "target", shape = "single", radius = 0 },
	exori_gran_flam = { kind = "target", shape = "single", radius = 0 },
	utani_gran_hur = { kind = "self", shape = "single", radius = 0 },
	exori_gran_frigo = { kind = "target", shape = "single", radius = 0 },
	exevo_gran_frigo_hur = {
		kind = "direction",
		shape = "squarewave",
		radius = 0,
		wod = { check = "additionalArea", name = "Strong Ice Wave" },
		byDir = {
		[0] = { {-1, -5}, {-1, -4}, {-1, -3}, {0, -5}, {0, -4}, {0, -3}, {0, -2}, {0, -1}, {1, -5}, {1, -4}, {1, -3} },
		[1] = { {1, 0}, {2, 0}, {3, -1}, {3, 0}, {3, 1}, {4, -1}, {4, 0}, {4, 1}, {5, -1}, {5, 0}, {5, 1} },
		[2] = { {-1, 3}, {-1, 4}, {-1, 5}, {0, 1}, {0, 2}, {0, 3}, {0, 4}, {0, 5}, {1, 3}, {1, 4}, {1, 5} },
		[3] = { {-5, -1}, {-5, 0}, {-5, 1}, {-4, -1}, {-4, 0}, {-4, 1}, {-3, -1}, {-3, 0}, {-3, 1}, {-2, 0}, {-1, 0} },
		[4] = { {-5, 3}, {-5, 4}, {-5, 5}, {-4, 3}, {-4, 4}, {-4, 5}, {-3, 3}, {-3, 4}, {-3, 5}, {-2, 2}, {-1, 1} },
		[5] = { {1, 1}, {2, 2}, {3, 3}, {3, 4}, {3, 5}, {4, 3}, {4, 4}, {4, 5}, {5, 3}, {5, 4}, {5, 5} },
		[6] = { {-5, -5}, {-5, -4}, {-5, -3}, {-4, -5}, {-4, -4}, {-4, -3}, {-3, -5}, {-3, -4}, {-3, -3}, {-2, -2}, {-1, -1} },
		[7] = { {1, -1}, {2, -2}, {3, -5}, {3, -4}, {3, -3}, {4, -5}, {4, -4}, {4, -3}, {5, -5}, {5, -4}, {5, -3} },
	},
		wodByDir = {
		[0] = { {-2, -5}, {-2, -4}, {-1, -5}, {-1, -4}, {-1, -3}, {-1, -2}, {0, -5}, {0, -4}, {0, -3}, {0, -2}, {0, -1}, {1, -5}, {1, -4}, {1, -3}, {1, -2}, {2, -5}, {2, -4} },
		[1] = { {1, 0}, {2, -1}, {2, 0}, {2, 1}, {3, -1}, {3, 0}, {3, 1}, {4, -2}, {4, -1}, {4, 0}, {4, 1}, {4, 2}, {5, -2}, {5, -1}, {5, 0}, {5, 1}, {5, 2} },
		[2] = { {-2, 4}, {-2, 5}, {-1, 2}, {-1, 3}, {-1, 4}, {-1, 5}, {0, 1}, {0, 2}, {0, 3}, {0, 4}, {0, 5}, {1, 2}, {1, 3}, {1, 4}, {1, 5}, {2, 4}, {2, 5} },
		[3] = { {-5, -2}, {-5, -1}, {-5, 0}, {-5, 1}, {-5, 2}, {-4, -2}, {-4, -1}, {-4, 0}, {-4, 1}, {-4, 2}, {-3, -1}, {-3, 0}, {-3, 1}, {-2, -1}, {-2, 0}, {-2, 1}, {-1, 0} },
		[4] = { {-7, 2}, {-6, 2}, {-6, 3}, {-5, 2}, {-5, 3}, {-5, 4}, {-4, 2}, {-4, 3}, {-4, 4}, {-4, 5}, {-3, 2}, {-3, 3}, {-3, 4}, {-3, 5}, {-3, 6}, {-2, 2}, {-2, 3}, {-2, 4}, {-2, 5}, {-2, 6}, {-2, 7}, {-1, 1} },
		[5] = { {1, 1}, {2, 2}, {2, 3}, {2, 4}, {2, 5}, {2, 6}, {2, 7}, {3, 2}, {3, 3}, {3, 4}, {3, 5}, {3, 6}, {4, 2}, {4, 3}, {4, 4}, {4, 5}, {5, 2}, {5, 3}, {5, 4}, {6, 2}, {6, 3}, {7, 2} },
		[6] = { {-7, -2}, {-6, -3}, {-6, -2}, {-5, -4}, {-5, -3}, {-5, -2}, {-4, -5}, {-4, -4}, {-4, -3}, {-4, -2}, {-3, -6}, {-3, -5}, {-3, -4}, {-3, -3}, {-3, -2}, {-2, -7}, {-2, -6}, {-2, -5}, {-2, -4}, {-2, -3}, {-2, -2}, {-1, -1} },
		[7] = { {1, -1}, {2, -7}, {2, -6}, {2, -5}, {2, -4}, {2, -3}, {2, -2}, {3, -6}, {3, -5}, {3, -4}, {3, -3}, {3, -2}, {4, -5}, {4, -4}, {4, -3}, {4, -2}, {5, -4}, {5, -3}, {5, -2}, {6, -3}, {6, -2}, {7, -2} },
	},
	},
	exori_gran_tera = { kind = "target", shape = "single", radius = 0 },
	utevo_res = { kind = "self", shape = "single", radius = 0 },
	utevo_gran_res_dru = { kind = "self", shape = "single", radius = 0 },
	utevo_gran_res_eq = { kind = "self", shape = "single", radius = 0 },
	utevo_gran_res_sac = { kind = "self", shape = "single", radius = 0 },
	utevo_gran_res_ven = { kind = "self", shape = "single", radius = 0 },
	exori_mas_nia = {
		kind = "direction",
		shape = "wave",
		radius = 0,
		byDir = {
		[0] = { {-2, -3}, {-2, -2}, {-2, -1}, {-2, 0}, {-1, -4}, {-1, -3}, {0, -4}, {0, -3}, {1, -4}, {1, -3}, {2, -3}, {2, -2}, {2, -1}, {2, 0} },
		[1] = { {0, -2}, {0, 2}, {1, -2}, {1, 2}, {2, -2}, {2, 2}, {3, -2}, {3, -1}, {3, 0}, {3, 1}, {3, 2}, {4, -1}, {4, 0}, {4, 1} },
		[2] = { {-2, 0}, {-2, 1}, {-2, 2}, {-2, 3}, {-1, 3}, {-1, 4}, {0, 3}, {0, 4}, {1, 3}, {1, 4}, {2, 0}, {2, 1}, {2, 2}, {2, 3} },
		[3] = { {-4, -1}, {-4, 0}, {-4, 1}, {-3, -2}, {-3, -1}, {-3, 0}, {-3, 1}, {-3, 2}, {-2, -2}, {-2, 2}, {-1, -2}, {-1, 2}, {0, -2}, {0, 2} },
	},
	},
	utamo_tempo_san = { kind = "self", shape = "single", radius = 0 },
	exori_infir_pug = { kind = "target", shape = "single", radius = 0 },
	exevo_ulus_tera = { kind = "self", shape = "single", radius = 3, tiles = { {-4, -1}, {-4, 0}, {-4, 1}, {-3, -2}, {-3, -1}, {-3, 0}, {-3, 1}, {-3, 2}, {-2, -3}, {-2, -2}, {-2, -1}, {-2, 0}, {-2, 1}, {-2, 2}, {-2, 3}, {-1, -4}, {-1, -3}, {-1, -2}, {-1, 2}, {-1, 3}, {-1, 4}, {0, -4}, {0, -3}, {0, -2}, {0, 2}, {0, 3}, {0, 4}, {1, -4}, {1, -3}, {1, -2}, {1, 2}, {1, 3}, {1, 4}, {2, -3}, {2, -2}, {2, -1}, {2, 0}, {2, 1}, {2, 2}, {2, 3}, {3, -2}, {3, -1}, {3, 0}, {3, 1}, {3, 2}, {4, -1}, {4, 0}, {4, 1} } },
	exori_tera = { kind = "target", shape = "single", radius = 0 },
	exevo_tera_hur = {
		kind = "direction",
		shape = "squarewave",
		radius = 0,
		byDir = {
		[0] = { {-1, -5}, {-1, -4}, {-1, -3}, {0, -5}, {0, -4}, {0, -3}, {0, -2}, {0, -1}, {1, -5}, {1, -4}, {1, -3} },
		[1] = { {1, 0}, {2, 0}, {3, -1}, {3, 0}, {3, 1}, {4, -1}, {4, 0}, {4, 1}, {5, -1}, {5, 0}, {5, 1} },
		[2] = { {-1, 3}, {-1, 4}, {-1, 5}, {0, 1}, {0, 2}, {0, 3}, {0, 4}, {0, 5}, {1, 3}, {1, 4}, {1, 5} },
		[3] = { {-5, -1}, {-5, 0}, {-5, 1}, {-4, -1}, {-4, 0}, {-4, 1}, {-3, -1}, {-3, 0}, {-3, 1}, {-2, 0}, {-1, 0} },
		[4] = { {-5, 3}, {-5, 4}, {-5, 5}, {-4, 3}, {-4, 4}, {-4, 5}, {-3, 3}, {-3, 4}, {-3, 5}, {-2, 2}, {-1, 1} },
		[5] = { {1, 1}, {2, 2}, {3, 3}, {3, 4}, {3, 5}, {4, 3}, {4, 4}, {4, 5}, {5, 3}, {5, 4}, {5, 5} },
		[6] = { {-5, -5}, {-5, -4}, {-5, -3}, {-4, -5}, {-4, -4}, {-4, -3}, {-3, -5}, {-3, -4}, {-3, -3}, {-2, -2}, {-1, -1} },
		[7] = { {1, -1}, {2, -2}, {3, -5}, {3, -4}, {3, -3}, {4, -5}, {4, -4}, {4, -3}, {5, -5}, {5, -4}, {5, -3} },
	},
	},
	exori_mas_amp_pug = { kind = "target", shape = "circle", radius = 3, tiles = { {-3, -1}, {-3, 0}, {-3, 1}, {-2, -2}, {-2, -1}, {-2, 0}, {-2, 1}, {-2, 2}, {-1, -3}, {-1, -2}, {-1, -1}, {-1, 0}, {-1, 1}, {-1, 2}, {-1, 3}, {0, -3}, {0, -2}, {0, -1}, {0, 0}, {0, 1}, {0, 2}, {0, 3}, {1, -3}, {1, -2}, {1, -1}, {1, 0}, {1, 1}, {1, 2}, {1, 3}, {2, -2}, {2, -1}, {2, 0}, {2, 1}, {2, 2}, {3, -1}, {3, 0}, {3, 1} } },
	exori_infir_nia = { kind = "target", shape = "single", radius = 0 },
	utito_mas_sio = { kind = "self", shape = "circle", radius = 5, tiles = { {-5, 0}, {-4, -1}, {-4, 0}, {-4, 1}, {-3, -2}, {-3, -1}, {-3, 0}, {-3, 1}, {-3, 2}, {-2, -3}, {-2, -2}, {-2, -1}, {-2, 0}, {-2, 1}, {-2, 2}, {-2, 3}, {-1, -4}, {-1, -3}, {-1, -2}, {-1, -1}, {-1, 0}, {-1, 1}, {-1, 2}, {-1, 3}, {-1, 4}, {0, -5}, {0, -4}, {0, -3}, {0, -2}, {0, -1}, {0, 0}, {0, 1}, {0, 2}, {0, 3}, {0, 4}, {0, 5}, {1, -4}, {1, -3}, {1, -2}, {1, -1}, {1, 0}, {1, 1}, {1, 2}, {1, 3}, {1, 4}, {2, -3}, {2, -2}, {2, -1}, {2, 0}, {2, 1}, {2, 2}, {2, 3}, {3, -2}, {3, -1}, {3, 0}, {3, 1}, {3, 2}, {4, -1}, {4, 0}, {4, 1}, {5, 0} } },
	exori_max_vis = { kind = "target", shape = "single", radius = 0 },
	exori_max_flam = { kind = "target", shape = "single", radius = 0 },
	exura_vita = { kind = "self", shape = "single", radius = 0 },
	exori_max_frigo = { kind = "target", shape = "single", radius = 0 },
	utevo_vis_lux = { kind = "self", shape = "single", radius = 0 },
	exori_max_tera = { kind = "target", shape = "single", radius = 0 },
	utori_virtu = { kind = "self", shape = "single", radius = 0 },
	utito_virtu = { kind = "self", shape = "single", radius = 0 },
	utura_tio = { kind = "self", shape = "single", radius = 0 },
	exori_hur = { kind = "target", shape = "single", radius = 0 },
	exura_ico = { kind = "self", shape = "single", radius = 0 },
	exevo_gran_mas_tera = { kind = "self", shape = "circle", radius = 6, tiles = { {-6, 0}, {-5, -1}, {-5, 0}, {-5, 1}, {-4, -2}, {-4, -1}, {-4, 0}, {-4, 1}, {-4, 2}, {-3, -3}, {-3, -2}, {-3, -1}, {-3, 0}, {-3, 1}, {-3, 2}, {-3, 3}, {-2, -4}, {-2, -3}, {-2, -2}, {-2, -1}, {-2, 0}, {-2, 1}, {-2, 2}, {-2, 3}, {-2, 4}, {-1, -5}, {-1, -4}, {-1, -3}, {-1, -2}, {-1, -1}, {-1, 0}, {-1, 1}, {-1, 2}, {-1, 3}, {-1, 4}, {-1, 5}, {0, -6}, {0, -5}, {0, -4}, {0, -3}, {0, -2}, {0, -1}, {0, 0}, {0, 1}, {0, 2}, {0, 3}, {0, 4}, {0, 5}, {0, 6}, {1, -5}, {1, -4}, {1, -3}, {1, -2}, {1, -1}, {1, 0}, {1, 1}, {1, 2}, {1, 3}, {1, 4}, {1, 5}, {2, -4}, {2, -3}, {2, -2}, {2, -1}, {2, 0}, {2, 1}, {2, 2}, {2, 3}, {2, 4}, {3, -3}, {3, -2}, {3, -1}, {3, 0}, {3, 1}, {3, 2}, {3, 3}, {4, -2}, {4, -1}, {4, 0}, {4, 1}, {4, 2}, {5, -1}, {5, 0}, {5, 1}, {6, 0} } },
}

CombatAutomationConfig.PotionEffects = {
	[266] = { health = { 125, 175 }, minLevel = 1, vocations = {} },
	[268] = { mana = { 75, 125 }, minLevel = 1, vocations = {} },
	[7876] = { health = { 60, 90 }, minLevel = 1, vocations = {} },
	[236] = { health = { 250, 350 }, minLevel = 50, vocations = { "paladin", "royal paladin", "knight", "elite knight", "monk", "exalted monk" } },
	[237] = { mana = { 115, 185 }, minLevel = 50, vocations = {} },
	[238] = { mana = { 150, 250 }, minLevel = 80, vocations = {} },
	[239] = { health = { 425, 575 }, minLevel = 80, vocations = { "knight", "elite knight" } },
	[7642] = { health = { 250, 350 }, mana = { 100, 200 }, minLevel = 80, vocations = { "paladin", "royal paladin", "monk", "exalted monk" } },
	[53162] = { mana = { 240, 360 }, minLevel = 100, vocations = { "paladin", "royal paladin", "sorcerer", "master sorcerer", "druid", "elder druid", "monk", "exalted monk" } },
	[7643] = { health = { 650, 850 }, minLevel = 130, vocations = { "knight", "elite knight" } },
	[23373] = { mana = { 425, 575 }, minLevel = 130, vocations = { "sorcerer", "master sorcerer", "druid", "elder druid" } },
	[23374] = { health = { 420, 580 }, mana = { 250, 350 }, minLevel = 130, vocations = { "paladin", "royal paladin", "monk", "exalted monk" } },
	[53163] = { mana = { 240, 360 }, minLevel = 130, vocations = {} },
	[23375] = { health = { 875, 1125 }, minLevel = 200, vocations = { "knight", "elite knight" } },
	[53164] = { mana = { 425, 575 }, minLevel = 200, vocations = {} },
}
-- END GENERATED COMBAT AUTOMATION CATALOG

-- Hand-maintained potions without HP/mana (the generator skips them). They live on the
-- Shield tab and are priced in tokens (TokenMarket) instead of NPC gold.
CombatAutomationConfig.SupportPotionEffects = {
	[35563] = {
		manashield = true,
		minLevel = 14,
		vocations = { "sorcerer", "master sorcerer", "druid", "elder druid" },
		tokenPrice = { id = 22516, count = 1 },
	},
}
for typeId, effect in pairs(CombatAutomationConfig.SupportPotionEffects) do
	CombatAutomationConfig.PotionEffects[typeId] = effect
end
