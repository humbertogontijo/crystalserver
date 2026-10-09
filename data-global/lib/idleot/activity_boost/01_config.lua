ActivityBoostConfig = ActivityBoostConfig or {}

-- Next free product opcode after reward chest (124).
ActivityBoostConfig.OPCODE = 125

ActivityBoostConfig.KV_SCOPE = "activity-boost"
-- Banked XP boost lasts until the next GlobalServerSave (no wall-clock TTL).
ActivityBoostConfig.DAILY_EARN_CAP_SEC = 50 * 60
ActivityBoostConfig.XP_BOOST_PERCENT = 50
ActivityBoostConfig.PURGE_TICK_MS = 60 * 1000

-- Fiendish forgeStack=15 → HP × (1 + (15*15+35)/100) = 3.6× (monster.cpp applyStacks).
ActivityBoostConfig.FIENDISH_HP_MULT = 3.6

ActivityBoostConfig.ACTIVITIES = {
	{
		id = "daily_hunt",
		name = "Daily Hunt",
		description = "Kill 250 creatures.",
		goal = 250,
		rewardSec = 10 * 60,
		destination = "expeditions_hunts",
		destinationLabel = "Expeditions · Hunts",
	},
	{
		id = "solo_boss",
		name = "Solo Boss",
		description = "Kill 3 solo bosses.",
		goal = 3,
		rewardSec = 10 * 60,
		destination = "expeditions_solo",
		destinationLabel = "Expeditions - Bosses - Solo",
	},
	{
		id = "world_boss",
		name = "World Boss",
		description = "Slay up to 3 world bosses.",
		goal = 3,
		rewardSec = 10 * 60,
		destination = "expeditions_world",
		destinationLabel = "Expeditions - Live - World Bosses",
	},
	{
		id = "fiendish_hunt",
		name = "Fiendish Hunt",
		description = "Clear 3 Fiendish hunts.",
		goal = 3,
		rewardSec = 10 * 60,
		destination = "fiendish_hunt",
		destinationLabel = "Expeditions · Fiendish Hunt",
	},
	{
		id = "bounty_hunter",
		name = "Bounty Hunter",
		description = "Complete 3 daily tasks.",
		goal = 3,
		rewardSec = 10 * 60,
		destination = "task_board_daily",
		destinationLabel = "Task Board · Daily",
	},
}

ActivityBoostConfig.WORLD_BOSS_DAILY_CAP = 3

-- Shared generic arena (Oramond Glooth Fairy room) for World Bosses with no spawn room.
ActivityBoostConfig.WORLD_BOSS_ARENA = {
	center = { x = 33688, y = 31937, z = 9 },
	boundary = { x = 33678, y = 31922, w = 22, h = 22 },
}

ActivityBoostConfig.WORLD_BOSS_SESSION_TIMES = { "12:00", "20:00" }
-- Entry respawn after a kill for generic-arena bosses (open spawns use their natural spawntime).
ActivityBoostConfig.WORLD_BOSS_COOLDOWN_SEC = 30 * 60
ActivityBoostConfig.WORLD_BOSS_FIGHT_SEC = 20 * 60

-- Boss + adds max HP grow with joined players: 1 + (players - 1) * PER_PLAYER, capped.
ActivityBoostConfig.WORLD_BOSS_HP_PER_EXTRA_PLAYER = 0.35
ActivityBoostConfig.WORLD_BOSS_HP_MULT_MAX = 8

-- BossDifficulty multipliers for gap variants (mirrors BossDifficulty.DEFAULTS).
ActivityBoostConfig.WORLD_BOSS_DIFFICULTY = { max = 25, hpPerLevel = 0.04, dmgPerLevel = 0.03 }

ActivityBoostConfig.WORLD_BOSS_LOOT_MULT = {
	[1] = 1.0,
	[2] = 0.7,
	[3] = 0.5,
	[4] = 0.35,
	[5] = 0.25,
}
ActivityBoostConfig.WORLD_BOSS_LOOT_MULT_FLOOR = 0.15

-- Per-boss entries from worldbosses.generated.json (`make generate`), sorted by levelMin.
ActivityBoostConfig.WORLD_BOSSES = {}
ActivityBoostConfig.WORLD_BOSS_BY_ID = {}

local function decodeHex(hex)
	return (tostring(hex or ""):gsub("%x%x", function(byte)
		return string.char(tonumber(byte, 16))
	end))
end

local function roomOccupancy(room)
	local occ = room and room.occupancy
	if type(occ) ~= "table" then
		return nil
	end
	return {
		originX = tonumber(occ.originX),
		originY = tonumber(occ.originY),
		width = tonumber(occ.width),
		height = tonumber(occ.height),
		bits = decodeHex(occ.bits),
		contains = CombatGeo.maskContains,
	}
end

function ActivityBoostConfig.loadWorldBosses()
	local path = DATA_DIRECTORY .. "/lib/idleot/activity_boost/worldbosses.generated.json"
	local file = io.open(path, "r")
	if not file then
		logger.error("[ActivityBoost] missing worldbosses.generated.json at {}", path)
		return
	end
	local content = file:read("*a")
	file:close()
	local data = JsonParser.decode(content)
	if type(data) ~= "table" or type(data.bosses) ~= "table" then
		logger.error("[ActivityBoost] worldbosses.generated.json decode failed")
		return
	end
	local list, byId = {}, {}
	for _, entry in ipairs(data.bosses) do
		if type(entry) == "table" and entry.id and entry.name then
			entry.id = tostring(entry.id)
			entry.levelMin = tonumber(entry.levelMin) or 1
			entry.difficulty = tonumber(entry.difficulty) or 0
			entry.adds = type(entry.adds) == "table" and entry.adds or {}
			if type(entry.room) == "table" then
				entry.room.occupancyMask = roomOccupancy(entry.room)
			end
			list[#list + 1] = entry
			byId[entry.id] = entry
		end
	end
	table.sort(list, function(a, b)
		if a.levelMin ~= b.levelMin then
			return a.levelMin < b.levelMin
		end
		return a.id < b.id
	end)
	ActivityBoostConfig.WORLD_BOSSES = list
	ActivityBoostConfig.WORLD_BOSS_BY_ID = byId
	logger.info("[ActivityBoost] loaded {} world boss entries", #list)
end

function ActivityBoostConfig.worldBoss(entryId)
	if entryId == nil then
		return nil
	end
	return ActivityBoostConfig.WORLD_BOSS_BY_ID[tostring(entryId)]
end

--- Name shown for an entry ("Latrivan & Golgordan", "Jaul (Difficulty 5)").
function ActivityBoostConfig.worldBossLabel(entry)
	if not entry then
		return "World Boss"
	end
	local label = entry.displayName or entry.name
	if (entry.difficulty or 0) > 0 then
		label = string.format("%s (Difficulty %d)", label, entry.difficulty)
	end
	return label
end

--- hp, dmg multipliers of a gap variant (1, 1 for base entries).
function ActivityBoostConfig.worldBossDifficultyMults(entry)
	local d = math.max(0, tonumber(entry and entry.difficulty) or 0)
	local cfg = ActivityBoostConfig.WORLD_BOSS_DIFFICULTY
	d = math.min(d, cfg.max)
	return 1 + d * cfg.hpPerLevel, 1 + d * cfg.dmgPerLevel
end

function ActivityBoostConfig.worldBossPlayerHpMult(players)
	local n = math.max(1, tonumber(players) or 1)
	local mult = 1 + (n - 1) * ActivityBoostConfig.WORLD_BOSS_HP_PER_EXTRA_PLAYER
	return math.min(mult, ActivityBoostConfig.WORLD_BOSS_HP_MULT_MAX)
end

ActivityBoostConfig.loadWorldBosses()
