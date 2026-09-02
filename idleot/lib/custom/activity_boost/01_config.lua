ActivityBoostConfig = ActivityBoostConfig or {}

-- Next free product opcode after reward chest (124).
ActivityBoostConfig.OPCODE = 125

ActivityBoostConfig.KV_SCOPE = "activity-boost"
-- Banked XP boost lasts until the next GlobalServerSave (no wall-clock TTL).
ActivityBoostConfig.DAILY_EARN_CAP_SEC = 40 * 60
ActivityBoostConfig.XP_BOOST_PERCENT = 50
ActivityBoostConfig.PURGE_TICK_MS = 60 * 1000

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
		destinationLabel = "Expeditions · Solo Bosses",
	},
	{
		id = "world_boss",
		name = "World Boss",
		description = "Slay up to 3 world bosses.",
		goal = 3,
		rewardSec = 10 * 60,
		destination = "expeditions_world",
		destinationLabel = "Expeditions · World Bosses",
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

ActivityBoostConfig.BOSS_RUSH_RANKS = {
	{ id = "S", maxSec = 180 },
	{ id = "A", maxSec = 300 },
	{ id = "B", maxSec = 480 },
	{ id = "C", maxSec = nil },
}

-- Tight player join gates. Same boss may appear in several adjacent bands.
ActivityBoostConfig.LEVEL_BANDS = {
	{ id = "50", name = "50–99", levelMin = 50, levelMax = 99 },
	{ id = "100", name = "100–149", levelMin = 100, levelMax = 149 },
	{ id = "150", name = "150–199", levelMin = 150, levelMax = 199 },
	{ id = "200", name = "200–249", levelMin = 200, levelMax = 249 },
	{ id = "250", name = "250–299", levelMin = 250, levelMax = 299 },
	{ id = "300", name = "300–349", levelMin = 300, levelMax = 349 },
	{ id = "350", name = "350–399", levelMin = 350, levelMax = 399 },
	{ id = "400", name = "400–499", levelMin = 400, levelMax = 499 },
	{ id = "500", name = "500–599", levelMin = 500, levelMax = 599 },
	{ id = "600", name = "600–799", levelMin = 600, levelMax = 799 },
	{ id = "800", name = "800+", levelMin = 800, levelMax = 9999 },
}

-- Curated Crystal world-boss roster (names only). Stats come from creature_info/creatures.generated.json.
ActivityBoostConfig.WORLD_BOSS_NAMES = {
	"Kroazur",
	"Mr. Punish",
	"Chikhaton",
	"Sir Leonard",
	"The Welter",
	"Sister Hetai",
	"Azerus",
	"Amenef the Burning",
	"Unaz the Mean",
	"Leiden",
	"Horadron",
	"Vok the Freakish",
	"Gralvalon",
	"The Ravager",
	"Lisa",
	"Glooth Fairy",
	"Bullwark",
	"Brain Head",
	"Professor Maxxen",
	"Lloyd",
	"The Sandking",
	"Deep Terror",
	"Versperoth",
	"Doctor Marrow",
	"Tremor Worm",
	"Apocalypse",
	"Lady Tenebris",
	"The Time Guardian",
	"The Freezing Time Guardian",
	"The Blazing Time Guardian",
	"Brother Worm",
	"Deathstrike",
	"Anomaly",
	"Rupture",
	"Eradicator",
	"Outburst",
	"Gnomevil",
	"The False God",
	"The Souldespoiler",
	"Plagueroot",
	"Malofur Mangrinder",
	"Maxxenius",
	"Alptramun",
	"Izcandar the Banished",
	"Prince Drazzak",
	"Abyssador",
	"The Baron from Below",
	"The Hungry Baron from Below",
	"The Count of the Core",
	"The Duke of the Depths",
	"Ragiaz",
	"Mazoran",
	"Plagirath",
	"Tarbaz",
	"Razzagorn",
	"Zamulosh",
	"Goshnar's Malice",
	"Goshnar's Cruelty",
	"Goshnar's Spite",
	"Goshnar's Hatred",
	"Goshnar's Greed",
	"The Rootkraken",
	"The Last Lore Keeper",
}

-- Resolved at load: { name, recommendedLevel, levelMin, combatPower, creatureId, bands }.
ActivityBoostConfig.WORLD_BOSSES = nil

-- Back-compat alias used by older helpers.
ActivityBoostConfig.WORLD_BOSS_SHORTLIST = nil -- filled after band resolve

-- Shared Oramond Glooth Fairy arena (instance-bound private copy).
ActivityBoostConfig.WORLD_BOSS_ARENA = {
	center = { x = 33688, y = 31937, z = 9 },
	boundary = { x = 33678, y = 31922, w = 22, h = 22 },
}

ActivityBoostConfig.WORLD_BOSS_SESSION_TIMES = { "12:00", "20:00" }
ActivityBoostConfig.WORLD_BOSS_COOLDOWN_SEC = 30 * 60
ActivityBoostConfig.WORLD_BOSS_FIGHT_SEC = 20 * 60
ActivityBoostConfig.WORLD_BOSS_RESPAWN_SEC = 10

ActivityBoostConfig.WORLD_BOSS_LOOT_MULT = {
	[1] = 1.0,
	[2] = 0.7,
	[3] = 0.5,
	[4] = 0.35,
	[5] = 0.25,
}
ActivityBoostConfig.WORLD_BOSS_LOOT_MULT_FLOOR = 0.15

-- Minimum roster size per band; sparse bands borrow adjacent bosses (gap fill).
ActivityBoostConfig.WORLD_BOSS_MIN_PER_BAND = 6

--- Map player level → LEVEL_BANDS index (1-based).
function ActivityBoostConfig.bandIndexForLevel(level)
	level = tonumber(level) or 1
	local bands = ActivityBoostConfig.LEVEL_BANDS or {}
	for i, band in ipairs(bands) do
		if level >= (band.levelMin or 0) and level <= (band.levelMax or 99999) then
			return i
		end
	end
	if #bands > 0 and level >= (bands[#bands].levelMin or 0) then
		return #bands
	end
	return 1
end

--- Neighbor bands only: primary from recommendedLevel, ±1 when near band edges (high/low stretch).
function ActivityBoostConfig.bandsForBoss(boss)
	local bands = ActivityBoostConfig.LEVEL_BANDS or {}
	local level = tonumber(boss and boss.recommendedLevel) or tonumber(boss and boss.levelMin) or 1
	local primary = ActivityBoostConfig.bandIndexForLevel(level)
	local out = {}
	local seen = {}
	local function addIdx(idx)
		if idx >= 1 and idx <= #bands then
			local id = bands[idx].id
			if not seen[id] then
				seen[id] = true
				out[#out + 1] = id
			end
		end
	end
	addIdx(primary)
	local band = bands[primary]
	if band then
		local span = math.max(1, (band.levelMax or level) - (band.levelMin or level))
		local edge = math.max(10, math.floor(span * 0.2))
		if level >= (band.levelMax or level) - edge then
			addIdx(primary + 1)
		end
		if level <= (band.levelMin or level) + edge then
			addIdx(primary - 1)
		end
	end
	return out
end

local function resolveBossEntry(name)
	local info = CreatureInfo and CreatureInfo.get(name)
	if not info then
		logger.warn("[ActivityBoost] world boss {} missing from creature_info", name)
		return {
			name = name,
			recommendedLevel = 1,
			levelMin = 1,
			combatPower = 0,
			creatureId = nil,
		}
	end
	return {
		name = name,
		recommendedLevel = tonumber(info.recommendedLevel) or tonumber(info.levelMin) or 1,
		levelMin = tonumber(info.levelMin) or 1,
		combatPower = tonumber(info.combatPower) or 0,
		creatureId = info.creatureId,
		hp = tonumber(info.hp) or 0,
		exp = tonumber(info.exp) or 0,
	}
end

local function fillBandGaps(byBand)
	local bands = ActivityBoostConfig.LEVEL_BANDS or {}
	local minPer = ActivityBoostConfig.WORLD_BOSS_MIN_PER_BAND or 6
	for i, band in ipairs(bands) do
		local pool = byBand[band.id]
		if pool and #pool < minPer then
			for _, delta in ipairs({ -1, 1 }) do
				local neighbor = bands[i + delta]
				if neighbor then
					local source = byBand[neighbor.id] or {}
					for _, bossName in ipairs(source) do
						if #pool >= minPer then
							break
						end
						local found = false
						for _, existing in ipairs(pool) do
							if existing == bossName then
								found = true
								break
							end
						end
						if not found then
							pool[#pool + 1] = bossName
						end
					end
				end
			end
		end
	end
end

--- Resolve shortlist + per-band boss pools (run once after config load).
function ActivityBoostConfig.resolveWorldBossPools()
	local names = ActivityBoostConfig.WORLD_BOSS_NAMES or {}
	local bosses = {}
	local shortlist = {}
	local byBand = {}
	for _, band in ipairs(ActivityBoostConfig.LEVEL_BANDS or {}) do
		byBand[band.id] = {}
	end
	for _, name in ipairs(names) do
		if type(name) == "string" and name ~= "" then
			local boss = resolveBossEntry(name)
			bosses[#bosses + 1] = boss
			shortlist[#shortlist + 1] = name
			local bandIds = boss.bands
			if type(bandIds) ~= "table" or #bandIds == 0 then
				bandIds = ActivityBoostConfig.bandsForBoss(boss)
			end
			boss.bands = bandIds
			for _, bandId in ipairs(bandIds) do
				local pool = byBand[bandId]
				if pool then
					pool[#pool + 1] = name
				end
			end
		end
	end
	fillBandGaps(byBand)
	ActivityBoostConfig.WORLD_BOSSES = bosses
	ActivityBoostConfig.WORLD_BOSS_SHORTLIST = shortlist
	ActivityBoostConfig.WORLD_BOSS_BY_BAND = byBand
	ActivityBoostConfig.WORLD_BOSS_POOLS = byBand
	return shortlist, byBand
end

ActivityBoostConfig.resolveWorldBossPools()
