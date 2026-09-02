TeamConfig = TeamConfig or {}

-- Distinct from expedition/combat (113) and player home (116).
TeamConfig.OPCODE = 117

-- Max simultaneous characters (primary + companions + friends).
TeamConfig.MAX_MEMBERS = 4

-- Storage: mark headless companions controlled by a primary guid.
TeamConfig.STORAGE_COMPANION_CONTROLLER = 910201
-- Storage snapshot of configured team (KV preferred; storage is backup flag).
TeamConfig.KV_MEMBERS = "account_team_members"
-- Same-account companion points at the character that owns the roster KV.
TeamConfig.KV_CONTROLLER_GUID = "account_team_controller_guid"
-- Legacy key from account-squad era (name list only).
TeamConfig.KV_MEMBERS_LEGACY = "account_squad_members"

TeamConfig.KIND_COMPANION = "companion"
TeamConfig.KIND_FRIEND = "friend"

-- Team-exclusive XP boost + prey (2× personal prices, full effect for roster).
TeamConfig.KV_BONUSES = "account_team_bonuses"
TeamConfig.XP_BOOST_PERCENT = 50
TeamConfig.XP_BOOST_DURATION_SEC = 3600
TeamConfig.XP_BOOST_PRICES = { 60, 90, 180, 360, 720 } -- 2× personal store ladder
TeamConfig.XP_BOOST_MAX_BUYS = 5
TeamConfig.PREY_SLOT_COUNT = 3
TeamConfig.PREY_BONUS_TIME_SEC = 7200 -- matches config preyBonusTime
TeamConfig.PREY_PRICE_MULT = 2
TeamConfig.PARTY_VOCATION_BONUS = {
	[1] = 1.20,
	[2] = 1.35,
	[3] = 1.70,
	[4] = 2.00,
}
TeamConfig.COMPANION_PARTY_WEIGHT = 0.5

-- Equip / bag slots mirrored for wire UI.
TeamConfig.EQUIP_SLOTS = {
	{ id = CONST_SLOT_HEAD, name = "head" },
	{ id = CONST_SLOT_NECKLACE, name = "necklace" },
	{ id = CONST_SLOT_BACKPACK, name = "backpack" },
	{ id = CONST_SLOT_ARMOR, name = "armor" },
	{ id = CONST_SLOT_RIGHT, name = "right" },
	{ id = CONST_SLOT_LEFT, name = "left" },
	{ id = CONST_SLOT_LEGS, name = "legs" },
	{ id = CONST_SLOT_FEET, name = "feet" },
	{ id = CONST_SLOT_RING, name = "ring" },
	{ id = CONST_SLOT_AMMO, name = "ammo" },
}
