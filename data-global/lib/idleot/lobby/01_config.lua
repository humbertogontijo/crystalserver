LobbyConfig = LobbyConfig or {}

-- Distinct from expedition (113), lobby travel / instance teleport (116), quests (118),
-- blessings (119), remote dialog (120), social friends (121).
LobbyConfig.OPCODE = 117

-- Slots per lobby (host + humans + alts); matches lever boss maxPlayers.
LobbyConfig.MAX_MEMBERS = 5
LobbyConfig.TITLE_MAX_LEN = 32
LobbyConfig.INVITE_TTL_SEC = 300
-- Start call countdown for members outside the lobby room.
LobbyConfig.CALL_TIMEOUT_SEC = 45

LobbyConfig.STATE_LOBBY = "lobby"
LobbyConfig.STATE_CALLING = "calling"
LobbyConfig.STATE_CHANNELING = "channeling"
LobbyConfig.STATE_RUNNING = "running"

LobbyConfig.PRESENCE_IN_LOBBY = "inLobby"
LobbyConfig.PRESENCE_IN_EXPEDITION = "inExpedition"
LobbyConfig.PRESENCE_BUSY = "busy"
LobbyConfig.PRESENCE_AWAY = "away"
LobbyConfig.PRESENCE_OFFLINE = "offline"

LobbyConfig.KIND_HUMAN = "human"
LobbyConfig.KIND_ALT = "alt"

-- Player KV: bonuses kept when a lobby dissolves, restored when that player hosts again.
LobbyConfig.KV_PARKED_BONUSES = "lobby_parked_bonuses"
-- Player KV: lobby id the player was inside when they logged out (relog restore).
LobbyConfig.KV_INSIDE_LOBBY = "lobby_inside_id"

-- Legacy KV converted once on login.
LobbyConfig.LEGACY_KV_TEAM_MEMBERS = "account_team_members"
LobbyConfig.LEGACY_KV_TEAM_CONTROLLER = "account_team_controller_guid"
LobbyConfig.LEGACY_KV_SQUAD_MEMBERS = "account_squad_members"
LobbyConfig.LEGACY_KV_TEAM_BONUSES = "account_team_bonuses"
LobbyConfig.LEGACY_KV_LISTING = "social_team_listing"

-- Lobby XP boost + team prey (2x personal prices, full effect for every member).
LobbyConfig.XP_BOOST_PERCENT = 50
LobbyConfig.XP_BOOST_DURATION_SEC = 3600
LobbyConfig.XP_BOOST_PRICES = { 60, 90, 180, 360, 720 }
LobbyConfig.XP_BOOST_MAX_BUYS = 5
LobbyConfig.PREY_SLOT_COUNT = 3
LobbyConfig.PREY_BONUS_TIME_SEC = 7200
LobbyConfig.PREY_PRICE_MULT = 2
LobbyConfig.PARTY_VOCATION_BONUS = {
	[1] = 1.20,
	[2] = 1.35,
	[3] = 1.70,
	[4] = 2.00,
}
LobbyConfig.ALT_PARTY_WEIGHT = 0.5

LobbyConfig.ROLE_MONSTER = "monster"
LobbyConfig.ROLE_BOSS = "boss"

-- Lobby room: one shared stamped footprint; each live lobby overlays it with a private
-- engine instance id. Nothing in the room is ever saved.
LobbyConfig.ROOM_BASE_X = 62040
LobbyConfig.ROOM_BASE_Y = 60000
LobbyConfig.ROOM_Z = 7
-- Interior floor (5 members + fixtures; SPAWN_OFFSETS has spare arrival tiles). Walls form a 1-tile ring around it.
LobbyConfig.ROOM_FLOOR_W = 9
LobbyConfig.ROOM_FLOOR_H = 7
LobbyConfig.ROOM_FLOOR_ID = 32820
LobbyConfig.ROOM_WALL_H = 32835
LobbyConfig.ROOM_WALL_V = 32826
LobbyConfig.ROOM_WALL_TL = 32828
LobbyConfig.ROOM_WALL_TR = 32829
LobbyConfig.ROOM_WALL_BL = 32831
LobbyConfig.ROOM_WALL_BR = 32830

-- Fixtures carry this action id; a move-item callback keeps them in place.
LobbyConfig.FIXTURE_ACTION_ID = 47100
LobbyConfig.EXERCISE_DUMMY_ID = 28559
LobbyConfig.IMBUEMENT_SHRINE_ID = 25175
LobbyConfig.DAILY_REWARD_SHRINE_ID = 25720
LobbyConfig.MAILBOX_ID = 23399
LobbyConfig.LOCKER_ID = 3497
LobbyConfig.LOCKER_COUNTER_NW_ID = 17391
LobbyConfig.LOCKER_SWITCH_NE_ID = 10145
LobbyConfig.LOCKER_COUNTER_SW_ID = 17393
LobbyConfig.LOCKER_TABLE_ID = 10050

-- Floor-local offsets from the NW interior tile.
function LobbyConfig.fixtureLayout()
	local lx = LobbyConfig.ROOM_FLOOR_W - 1
	local ly = LobbyConfig.ROOM_FLOOR_H - 1
	return {
		{ id = LobbyConfig.IMBUEMENT_SHRINE_ID, dx = 0, dy = 0, key = "shrinePos" },
		{ id = LobbyConfig.DAILY_REWARD_SHRINE_ID, dx = 1, dy = 0, key = "rewardPos" },
		{ id = LobbyConfig.EXERCISE_DUMMY_ID, dx = lx, dy = 0, key = "dummyPos" },
		{ id = LobbyConfig.MAILBOX_ID, dx = 0, dy = ly, key = "mailboxPos" },
		{ id = LobbyConfig.LOCKER_COUNTER_NW_ID, dx = lx - 1, dy = ly - 1 },
		{ id = LobbyConfig.LOCKER_SWITCH_NE_ID, dx = lx, dy = ly - 1 },
		{ id = LobbyConfig.LOCKER_COUNTER_SW_ID, dx = lx - 1, dy = ly },
		{ id = LobbyConfig.LOCKER_TABLE_ID, dx = lx, dy = ly },
		{ id = LobbyConfig.LOCKER_ID, dx = lx, dy = ly, key = "lockerPos" },
	}
end

-- Arrival tiles around the room center (floor-local), one per creature.
LobbyConfig.SPAWN_OFFSETS = {
	{ 4, 3 },
	{ 3, 2 },
	{ 5, 2 },
	{ 3, 4 },
	{ 5, 4 },
	{ 4, 2 },
	{ 4, 4 },
	{ 2, 3 },
	{ 6, 3 },
}

-- Runtime storages (not storages.xml): open-world tile to return to when leaving the room.
LobbyConfig.STORAGE_RETURN_X = 910111
LobbyConfig.STORAGE_RETURN_Y = 910112
LobbyConfig.STORAGE_RETURN_Z = 910113

-- Exercise training on the room dummy (opcode 116 startTraining / stopTraining).
LobbyConfig.TRAVEL_OPCODE = 116
LobbyConfig.TRAIN_SKILL_TRIES = 7
LobbyConfig.TRAIN_MANA_SPENT = 600
LobbyConfig.EXERCISE_WEAPONS = {
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
	[50293] = { skill = "fist" },
	[50294] = { skill = "fist" },
	[50295] = { skill = "fist" },
}

--- Sorted server item ids for a training skill (stable consume order).
function LobbyConfig.weaponsForSkill(skill)
	local ids = {}
	for id, meta in pairs(LobbyConfig.EXERCISE_WEAPONS) do
		if meta.skill == skill then
			ids[#ids + 1] = id
		end
	end
	table.sort(ids)
	return ids
end
