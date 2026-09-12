PlayerHomeConfig = PlayerHomeConfig or {}

-- Client extended opcode (next free after hireling 115).
PlayerHomeConfig.OPCODE = 116

-- Shared world footprint; concurrent homes use private engine instance ids.
PlayerHomeConfig.INSTANCE_BASE_X = 62000
PlayerHomeConfig.INSTANCE_BASE_Y = 60000
PlayerHomeConfig.INSTANCE_Z = 7

-- Ephemeral runtime house (not in houses.xml / tile_store).
PlayerHomeConfig.HOUSE_ID = 900000

-- Interior floor size (house SQMs). Walls form a 1-tile ring around this.
PlayerHomeConfig.FLOOR_SIZE = 7
-- Full stamp footprint including wall ring.
PlayerHomeConfig.OUTER_SIZE = PlayerHomeConfig.FLOOR_SIZE + 2

-- Ground + wall tiles (mysterious ground / mysterious wall).
PlayerHomeConfig.FLOOR_ID = 32820
PlayerHomeConfig.WALL_H = 32835
PlayerHomeConfig.WALL_V = 32826
PlayerHomeConfig.WALL_TL = 32828
PlayerHomeConfig.WALL_TR = 32829
PlayerHomeConfig.WALL_BL = 32831
PlayerHomeConfig.WALL_BR = 32830

-- Runtime storages (not storages.xml).
PlayerHomeConfig.STORAGE_RETURN_X = 910101
PlayerHomeConfig.STORAGE_RETURN_Y = 910102
PlayerHomeConfig.STORAGE_RETURN_Z = 910103

PlayerHomeConfig.ZONE_NAME = "player-home"
PlayerHomeConfig.ZONE_PREFIX = "player-home"

-- Identity place id for topbar / instanceBounds (no client fence).
PlayerHomeConfig.PLACE_ID = 0

-- House-equivalent movable furniture (wrapable / usedbyhouseguests depot).
-- Floor-local offsets are from floorOrigin (NW interior tile).
PlayerHomeConfig.EXERCISE_DUMMY_ID = 28559 -- ferumbras exercise dummy (house)
PlayerHomeConfig.IMBUEMENT_SHRINE_ID = 25175 -- imbuing shrine (house)
PlayerHomeConfig.DAILY_REWARD_SHRINE_ID = 25720 -- reward shrine (house)
PlayerHomeConfig.MAILBOX_ID = 23399 -- mailbox (house)
PlayerHomeConfig.LOCKER_ID = 3497 -- locker (house depot)
-- Depot-style 2x2 corner (from Thais depot OTBM 32349..32350, 32201..32202, z7).
PlayerHomeConfig.LOCKER_COUNTER_NW_ID = 17391
PlayerHomeConfig.LOCKER_SWITCH_NE_ID = 10145
PlayerHomeConfig.LOCKER_COUNTER_SW_ID = 17393
PlayerHomeConfig.LOCKER_TABLE_ID = 10050 -- under the locker on the map
-- SE interior corner of the 7x7 floor (NW tile of the 2x2 block).
PlayerHomeConfig.LOCKER_CORNER_DX = 6
PlayerHomeConfig.LOCKER_CORNER_DY = 6

-- Defaults match slot-0 world coords (floorOrigin = INSTANCE_BASE + 1):
--   imbuing  (62001,60001,7) → (0,0)
--   reward   (62002,60001,7) → (1,0)
--   mailbox  (62001,60007,7) → (0,6)
PlayerHomeConfig.FURNITURE = {
	{ id = PlayerHomeConfig.IMBUEMENT_SHRINE_ID, dx = 0, dy = 0, key = "shrinePos" },
	{ id = PlayerHomeConfig.DAILY_REWARD_SHRINE_ID, dx = 1, dy = 0, key = "rewardPos" },
	{ id = PlayerHomeConfig.EXERCISE_DUMMY_ID, dx = 5, dy = 1, key = "dummyPos" },
	{ id = PlayerHomeConfig.MAILBOX_ID, dx = 0, dy = 6, key = "mailboxPos" },
}

--- Per-player starter furniture (never stamped on the shared instance-0 template).
function PlayerHomeConfig.starterLayout()
	local layout = {}
	for _, spec in ipairs(PlayerHomeConfig.FURNITURE or {}) do
		if spec.id then
			layout[#layout + 1] = { id = spec.id, dx = spec.dx or 0, dy = spec.dy or 0 }
		end
	end
	return layout
end

--- Shared depot corner on the instance-0 template (not per-player furniture).
function PlayerHomeConfig.lockerLayout()
	local lockerDx = PlayerHomeConfig.LOCKER_CORNER_DX or 6
	local lockerDy = PlayerHomeConfig.LOCKER_CORNER_DY or 6
	return {
		{ id = PlayerHomeConfig.LOCKER_COUNTER_NW_ID, dx = lockerDx - 1, dy = lockerDy - 1 },
		{ id = PlayerHomeConfig.LOCKER_SWITCH_NE_ID, dx = lockerDx, dy = lockerDy - 1 },
		{ id = PlayerHomeConfig.LOCKER_COUNTER_SW_ID, dx = lockerDx - 1, dy = lockerDy },
		{ id = PlayerHomeConfig.LOCKER_TABLE_ID, dx = lockerDx, dy = lockerDy },
		{ id = PlayerHomeConfig.LOCKER_ID, dx = lockerDx, dy = lockerDy },
	}
end

--- True if item id is the shared locker / locker-corner fixture.
function PlayerHomeConfig.isSharedLockerId(itemId)
	itemId = tonumber(itemId) or 0
	if itemId <= 0 then
		return false
	end
	return itemId == PlayerHomeConfig.LOCKER_ID
		or itemId == PlayerHomeConfig.LOCKER_COUNTER_NW_ID
		or itemId == PlayerHomeConfig.LOCKER_SWITCH_NE_ID
		or itemId == PlayerHomeConfig.LOCKER_COUNTER_SW_ID
		or itemId == PlayerHomeConfig.LOCKER_TABLE_ID
end

--- True if item id is starter furniture (always persist). Locker is not furniture.
function PlayerHomeConfig.isFurnitureId(itemId)
	itemId = tonumber(itemId) or 0
	if itemId <= 0 then
		return false
	end
	if PlayerHomeConfig.isSharedLockerId(itemId) then
		return false
	end
	if itemId == PlayerHomeConfig.EXERCISE_DUMMY_ID
		or itemId == PlayerHomeConfig.IMBUEMENT_SHRINE_ID
		or itemId == PlayerHomeConfig.DAILY_REWARD_SHRINE_ID
		or itemId == PlayerHomeConfig.MAILBOX_ID
	then
		return true
	end
	for _, spec in ipairs(PlayerHomeConfig.FURNITURE or {}) do
		if spec.id == itemId then
			return true
		end
	end
	return false
end

-- Spawned in the home instance (same NPC type as remote hireling trade).
PlayerHomeConfig.HIRELING_NPC = "Remote Hireling Trader"
-- Floor-local offsets from floorOrigin (NW interior tile).
PlayerHomeConfig.HIRELING_FLOOR_DX = 0
PlayerHomeConfig.HIRELING_FLOOR_DY = 4 -- SW-ish interior; shrine NW, dummy NE
-- Forgotten Knowledge tomes storage id (resolved lazily - Storage may load later).
PlayerHomeConfig.STORAGE_SHAPER_TOMES = 0

PlayerHomeConfig.TRAIN_TICK_MS = 2000
PlayerHomeConfig.TRAIN_SKILL_TRIES = 7
PlayerHomeConfig.TRAIN_MANA_SPENT = 600

function PlayerHomeConfig.shaperTomesStorage()
	if PlayerHomeConfig.STORAGE_SHAPER_TOMES and PlayerHomeConfig.STORAGE_SHAPER_TOMES > 0 then
		return PlayerHomeConfig.STORAGE_SHAPER_TOMES
	end
	local id = Storage
		and Storage.Quest
		and Storage.Quest.U11_02
		and Storage.Quest.U11_02.ForgottenKnowledge
		and Storage.Quest.U11_02.ForgottenKnowledge.Tomes
	if type(id) == "number" then
		PlayerHomeConfig.STORAGE_SHAPER_TOMES = id
		return id
	end
	return 0
end

-- Exercise weapon server ids → skill (mirrors crystal exercise_training_weapons.lua).
PlayerHomeConfig.EXERCISE_WEAPONS = {
	[28552] = { skill = "sword" },
	[35279] = { skill = "sword" },
	[35285] = { skill = "sword" },
	[28553] = { skill = "axe" },
	[35280] = { skill = "axe" },
	[35286] = { skill = "axe" },
	[28554] = { skill = "club" },
	[35281] = { skill = "club" },
	[35287] = { skill = "club" },
	[28555] = { skill = "distance", effect = CONST_ANI_SIMPLEARROW, allowFarUse = true },
	[35282] = { skill = "distance", effect = CONST_ANI_SIMPLEARROW, allowFarUse = true },
	[35288] = { skill = "distance", effect = CONST_ANI_SIMPLEARROW, allowFarUse = true },
	[28556] = { skill = "magic", effect = CONST_ANI_SMALLICE, allowFarUse = true },
	[35283] = { skill = "magic", effect = CONST_ANI_SMALLICE, allowFarUse = true },
	[35289] = { skill = "magic", effect = CONST_ANI_SMALLICE, allowFarUse = true },
	[28557] = { skill = "magic", effect = CONST_ANI_FIRE, allowFarUse = true },
	[35284] = { skill = "magic", effect = CONST_ANI_FIRE, allowFarUse = true },
	[35290] = { skill = "magic", effect = CONST_ANI_FIRE, allowFarUse = true },
	[44065] = { skill = "shield" },
	[44066] = { skill = "shield" },
	[44067] = { skill = "shield" },
}

--- Skill name for an exercise weapon item id.
function PlayerHomeConfig.weaponSkill(itemId)
	itemId = tonumber(itemId) or 0
	local meta = PlayerHomeConfig.EXERCISE_WEAPONS[itemId]
	return meta and meta.skill or nil
end

--- Sorted server item ids for a training skill (stable consume order).
function PlayerHomeConfig.weaponsForSkill(skill)
	if type(skill) ~= "string" or skill == "" then
		return {}
	end
	local ids = {}
	for id, meta in pairs(PlayerHomeConfig.EXERCISE_WEAPONS or {}) do
		if meta.skill == skill then
			ids[#ids + 1] = id
		end
	end
	table.sort(ids)
	return ids
end

function PlayerHomeConfig.zoneName()
	return PlayerHomeConfig.ZONE_NAME
end

--- True if zone name belongs to a personal-home instance.
function PlayerHomeConfig.isHomeZoneName(name)
	if type(name) ~= "string" then
		return false
	end
	return name:sub(1, #PlayerHomeConfig.ZONE_PREFIX) == PlayerHomeConfig.ZONE_PREFIX
end
