ExpeditionConfig = ExpeditionConfig or {}

ExpeditionConfig.OPCODE = 113

-- Runtime storage (not DB storages.xml) for expedition flags.
ExpeditionConfig.STORAGE_ACTIVE = 910001
ExpeditionConfig.STORAGE_EXPEDITION_ID = 910002
ExpeditionConfig.STORAGE_RETURN_X = 910003
ExpeditionConfig.STORAGE_RETURN_Y = 910004
ExpeditionConfig.STORAGE_RETURN_Z = 910005

-- Player KV: pending hunt restore pointer (session key in global expeditions/hunts KV).
ExpeditionConfig.KV_HUNT_KEY = "expedition_hunt_key"
-- Player KV: expedition boss attempt in progress (refund cooldown on death/restart if unsettled).
ExpeditionConfig.KV_BOSS_ATTEMPT = "expedition_boss_attempt"
-- Drop stale hunt restore blobs after this many seconds (0 = no expiry).
ExpeditionConfig.HUNT_RESTORE_TTL_SEC = 7 * 24 * 3600

-- Hunt / expedition clustering FOV — must match Crystal map_const.hpp
-- MAP_MAX_CLIENT_VIEW_PORT_* (visible-sqm 12 @ 21:9 → aware radius 15).
ExpeditionConfig.MAP_MAX_CLIENT_VIEW_PORT_X = 15
ExpeditionConfig.MAP_MAX_CLIENT_VIEW_PORT_Y = 15
-- Soft A* bias for non-anchors. Past this many classic viewports (Chebyshev
-- half-extent 8, matching combat automation VIEWPORT_X), tiles farther from
-- the anchor than the player is now cost extra. 0 disables.
ExpeditionConfig.ANCHOR_PATH_BIAS_VIEWPORTS = 1
ExpeditionConfig.ANCHOR_PATH_BIAS_VIEWPORT = 8

--- Chebyshev radius of the non-anchor path bias. 0 disables.
function ExpeditionConfig.anchorPathBiasRadius()
	local viewports = math.floor(tonumber(ExpeditionConfig.ANCHOR_PATH_BIAS_VIEWPORTS) or 1)
	local viewport = math.floor(tonumber(ExpeditionConfig.ANCHOR_PATH_BIAS_VIEWPORT) or 8)
	if viewports <= 0 or viewport <= 0 then
		return 0
	end
	return viewports * viewport
end

ExpeditionConfig.SUBAREA_DIR = "lib/idleot/subareas"
-- Voluntary leave: server delays eject this many seconds (client shows the same countdown).
ExpeditionConfig.LEAVE_COUNTDOWN_SEC = 5
-- Shared team-accept ready check (host + invitees). Expiry cancels the waiting lobby.
ExpeditionConfig.TEAM_ACCEPT_TIMEOUT_SEC = 45
-- Map-spawn lure hunts (ExpeditionPack + Cavebot). Instance spawns come
-- from the world spawn XML; monsters keep stock behaviour (engage on sight, walk back
-- to their spawn on losing the party; homes are never moved). Cave walker and lure
-- pacing knobs live in CavebotConfig (lib/idleot/cavebot/01_config.lua).
-- Lure-hunt monsters keep chasing a target they already have this many sqm past their
-- normal sight, so trailing monsters follow the anchor to the next halt.
ExpeditionConfig.TARGET_KEEP_SQM = 4
-- Classic Tibia spawn flash (matches SpawnMonster::NONBLOCKABLE_SPAWN_MONSTER_INTERVAL).
ExpeditionConfig.PRE_SPAWN_FLASHES = 3
ExpeditionConfig.PRE_SPAWN_INTERVAL_MS = 1400
-- After instance teleport, wait before AI/spawn so OTC finishes map description.
ExpeditionConfig.ENTRY_CLIENT_SYNC_MS = 500

--- Safety options for ending an expedition when supplies cannot be paid / carried.
--- Both default to false (explicit opt-in; new players often have 0 gold).
---
--- Shortage meanings (see ExpeditionSafety.handleShortage):
---   insufficient gold — cannot restock a needed supply (potion/rune/ammo) at NPC buy
---     price from inventory+bank; not merely gold == 0 while stacks remain.
---   insufficient capacity — cannot collect an accepted loot item by weight (free cap <
---     item weight); not merely freeCap == 0 and not "cannot carry one ammo unit".
--- Auto-sell (when enabled + sell-on-insufficient-*) runs on loot drop before C++
--- auto-loot and again before expedition stop; stop does not require auto-sell.
function ExpeditionConfig.normalizeStopOptions(opts)
	if type(opts) ~= "table" then
		opts = {}
	end
	return {
		stopOnInsufficientGold = opts.stopOnInsufficientGold == true,
		stopOnInsufficientCap = opts.stopOnInsufficientCap == true,
	}
end

-- Post-clear loot window before eject/sweep (boss, Fiendish Hunt, raid).
ExpeditionConfig.LOOT_GRACE_MS = 5000
-- Fallback when configKeys.BOSS_DEFAULT_TIME_TO_DEFEAT is unavailable (lever timeout).
ExpeditionConfig.BOSS_TIME_TO_DEFEAT_SEC = 20 * 60
-- A boss whose mechanic is played keeps its immunity this long before it is stripped.
ExpeditionConfig.BOSS_MECHANIC_STALL_SEC = 60
-- Fallback when raids.xml interval2 is missing (matches typical interval2=1440).
ExpeditionConfig.RAID_DESPAWN_FALLBACK_MS = 24 * 60 * 60 * 1000
--- Pick session.anchorPlayerId (Cavebot.electAnchor over living, not dead-flagged members). Every member is a candidate:
--- inside an expedition the cavebot only pauses, it is never stopped.
function ExpeditionConfig.pickAnchor(session)
	if not session then
		return nil
	end
	local anchor = Cavebot.electAnchor(ExpeditionManager.sessionMemberIds(session), session.deadPlayerIds)
	if not anchor then
		-- Fallback: host if online, else first listed id.
		if session.playerId and Player(session.playerId) then
			session.anchorPlayerId = session.playerId
			return session.anchorPlayerId
		end
		if type(session.playerIds) == "table" and session.playerIds[1] then
			session.anchorPlayerId = session.playerIds[1]
			return session.anchorPlayerId
		end
		session.anchorPlayerId = nil
		return nil
	end

	session.anchorPlayerId = anchor:getId()
	return session.anchorPlayerId
end

function ExpeditionConfig.getAnchorPlayer(session)
	if not session then
		return nil
	end
	local anchorId = session.anchorPlayerId
	if not anchorId then
		anchorId = ExpeditionConfig.pickAnchor(session)
	end
	if not anchorId then
		return nil
	end
	local player = Player(anchorId)
	if player and player:getHealth() > 0 then
		local dead = session.deadPlayerIds
		if not (dead and dead[anchorId]) then
			return player
		end
	end
	-- Stale id (left/dead): re-pick once.
	anchorId = ExpeditionConfig.pickAnchor(session)
	if not anchorId then
		return nil
	end
	return Player(anchorId)
end

-- Shared Lua raids redirected into expedition slots (see 09_raid_instance.lua).
-- Wait after the last stage starts before allowing "all clear" (covers spawn flash delay).
-- Actual eligibility is max(this, raid.timeToSpawnMonsters + 2000); grace also requires a successful spawn.
ExpeditionConfig.RAID_CLEAR_ELIGIBLE_DELAY_MS = 5000
-- Deaths / spawns recount at once; this loop only catches monsters removed without dying.
ExpeditionConfig.RAID_WATCH_INTERVAL_MS = 10000
ExpeditionConfig.RAID_ARENA_KIND = "raid"
ExpeditionConfig.RAID_JOIN_HINT = "Join via Expeditions > Raids."
-- How many shared raid instances may run at once (XML + Lua Raid.registry).
ExpeditionConfig.RAID_MAX_CONCURRENT = 2
-- XML import: first-check chance and per-row / per-raid spawn caps.
ExpeditionConfig.RAID_XML_INITIAL_CHANCE = 0.12
ExpeditionConfig.RAID_XML_MAX_CHANCE_PER_CHECK = 0.08
ExpeditionConfig.RAID_XML_MAX_AMOUNT = 8
ExpeditionConfig.RAID_XML_MAX_TOTAL = 32
-- raids.xml interval2 (minutes) → ms, keyed by raid id (see catalog.generated.json).
ExpeditionConfig.RaidIntervalsMs = ExpeditionConfig.RaidIntervalsMs or {}

--- Catalog / RaidArenaCenters key (must match packages/asset-pipeline/data/raid-arenas.json).
function ExpeditionConfig.raidRegionId(raidName)
	if type(raidName) ~= "string" then
		return nil
	end
	return raidName:gsub("[%.%-]", "_")
end

-- Aliases to CombatAutomationConfig catalogs (owned by lib/idleot/combat_automation/).
ExpeditionConfig.PotionEffects = CombatAutomationConfig and CombatAutomationConfig.PotionEffects or {}
ExpeditionConfig.AllowedRunes = CombatAutomationConfig and CombatAutomationConfig.AllowedRunes or {}
ExpeditionConfig.AllowedSpellWords = CombatAutomationConfig and CombatAutomationConfig.AllowedSpellWords or {}
ExpeditionConfig.SpellWordsById = CombatAutomationConfig and CombatAutomationConfig.SpellWordsById or {}

-- Catalog JSON (generated into data/canary/.../lib/idleot/expeditions/catalog.generated.json).
-- Regenerate: bun run --filter=@idleot/asset-pipeline generate:catalog
ExpeditionConfig.Catalog = ExpeditionConfig.Catalog or {}
ExpeditionConfig.Cities = ExpeditionConfig.Cities or {}
ExpeditionConfig.RaidArenaCenters = ExpeditionConfig.RaidArenaCenters or {}
ExpeditionConfig.RaidLevels = ExpeditionConfig.RaidLevels or {}
ExpeditionConfig.RaidRoles = ExpeditionConfig.RaidRoles or {}
ExpeditionConfig.RaidIntervalsMs = ExpeditionConfig.RaidIntervalsMs or {}

local function catalogCombatPower(entry)
	return tonumber(entry and entry.combatPower) or 0
end

local function catalogSortName(entry)
	return string.lower(tostring(entry and entry.name or ""))
end

local function catalogFloorOffset(entry)
	return tonumber(entry and entry.floorOffset) or 0
end

local function catalogEntryScore(entry)
	return tonumber(entry and entry.score) or 0
end

-- Mirrors packages/asset-pipeline/src/expedition/domain/hunt-levels.ts HUNT_BANDS.
local CATALOG_LEVEL_BANDS = {
	{ id = "1-7", lo = 1, hi = 7 },
	{ id = "8-19", lo = 8, hi = 19 },
	{ id = "20-34", lo = 20, hi = 34 },
	{ id = "35-49", lo = 35, hi = 49 },
	{ id = "50-79", lo = 50, hi = 79 },
	{ id = "80-99", lo = 80, hi = 99 },
	{ id = "100-149", lo = 100, hi = 149 },
	{ id = "150-199", lo = 150, hi = 199 },
	{ id = "200-249", lo = 200, hi = 249 },
	{ id = "250-299", lo = 250, hi = 299 },
	{ id = "300-399", lo = 300, hi = 399 },
	{ id = "400-549", lo = 400, hi = 549 },
	{ id = "550-599", lo = 550, hi = 599 },
	{ id = "600+", lo = 600, hi = nil },
}

function ExpeditionConfig.catalogLevelBand(entry)
	if type(entry) ~= "table" then
		return ""
	end
	local band = entry.levelBand
	if type(band) == "string" and band ~= "" then
		return band
	end
	local level = tonumber(entry.recommendedLevel) or tonumber(entry.levelMin) or 1
	for _, row in ipairs(CATALOG_LEVEL_BANDS) do
		if level >= row.lo then
			if row.hi == nil or level <= row.hi then
				return row.id
			end
		end
	end
	return ""
end

--- Stable creature mix key: sorted creatureId:percent pairs.
function ExpeditionConfig.catalogCreatureSignature(entry)
	if type(entry) ~= "table" then
		return ""
	end
	local sig = entry.creatureSignature
	if type(sig) == "string" and sig ~= "" then
		return sig
	end
	local creatures = entry.creatures
	if type(creatures) ~= "table" or #creatures == 0 then
		local cid = tonumber(entry.creatureId)
		if cid and cid > 0 then
			return tostring(cid) .. ":100"
		end
		return ""
	end
	local parts = {}
	for _, c in ipairs(creatures) do
		local cid = c and tonumber(c.creatureId)
		if cid and cid > 0 then
			parts[#parts + 1] = string.format("%d:%d", cid, math.floor(tonumber(c.percent) or 0))
		end
	end
	table.sort(parts)
	return table.concat(parts, ",")
end

--- Each hunt/floor is its own catalog entry (no floor-family or mix grouping).
function ExpeditionConfig.buildCatalogDisplayMetadata()
	local catalog = ExpeditionConfig.Catalog
	if type(catalog) ~= "table" then
		ExpeditionConfig.FloorFamilies = {}
		return
	end

	ExpeditionConfig.FloorFamilies = {}
	for _, entry in ipairs(catalog) do
		entry._displayRepresentative = true
		entry._displayAlternates = nil
		entry._displayFloorMembers = nil
	end
end

--- Levels are derived from combat power; sort by each entry's own power.
function ExpeditionConfig.sortCatalogForDisplay(catalog)
	if type(catalog) ~= "table" then
		return
	end
	table.sort(catalog, function(a, b)
		local cpA = catalogCombatPower(a)
		local cpB = catalogCombatPower(b)
		if cpA ~= cpB then
			return cpA < cpB
		end
		local nameA = catalogSortName(a)
		local nameB = catalogSortName(b)
		if nameA ~= nameB then
			return nameA < nameB
		end
		local offA = catalogFloorOffset(a)
		local offB = catalogFloorOffset(b)
		if offA ~= offB then
			return offA < offB
		end
		return (tonumber(a.id) or 0) < (tonumber(b.id) or 0)
	end)
end

local function loadGeneratedCatalog()
	local path = DATA_DIRECTORY .. "/lib/idleot/expeditions/catalog.generated.json"
	local file = io.open(path, "r")
	if not file then
		logger.error("[Expedition] missing catalog.generated.json at {}", path)
		ExpeditionConfig.Catalog = {}
		ExpeditionConfig.Cities = {}
		ExpeditionConfig.RaidArenaCenters = {}
		ExpeditionConfig.RaidLevels = {}
		ExpeditionConfig.RaidRoles = {}
		ExpeditionConfig.RaidIntervalsMs = {}
		return
	end
	local content = file:read("*a")
	file:close()
	local data = JsonParser.decode(content)
	if type(data) ~= "table" then
		logger.error("[Expedition] catalog.generated.json decode failed")
		ExpeditionConfig.Catalog = {}
		ExpeditionConfig.Cities = {}
		ExpeditionConfig.RaidArenaCenters = {}
		ExpeditionConfig.RaidLevels = {}
		ExpeditionConfig.RaidRoles = {}
		ExpeditionConfig.RaidIntervalsMs = {}
		return
	end
	ExpeditionConfig.Catalog = data.catalog or {}
	ExpeditionConfig.sortCatalogForDisplay(ExpeditionConfig.Catalog)
	ExpeditionConfig.buildCatalogDisplayMetadata()
	ExpeditionConfig.Cities = data.cities or {}
	ExpeditionConfig.RaidArenaCenters = data.raidArenaCenters or {}
	ExpeditionConfig.RaidLevels = data.raidLevels or {}
	ExpeditionConfig.RaidRoles = data.raidRoles or {}
	ExpeditionConfig.RaidIntervalsMs = data.raidIntervalsMs or {}
	logger.info("[Expedition] loaded {} catalog entries + {} cities from JSON", #ExpeditionConfig.Catalog, #ExpeditionConfig.Cities)
end

function ExpeditionConfig.subareaMaskPath(file)
	if type(file) ~= "string" or file == "" then
		return nil
	end
	return DATA_DIRECTORY .. "/" .. ExpeditionConfig.SUBAREA_DIR .. "/" .. file
end

loadGeneratedCatalog()

--- Ephemeral catalog entries (e.g. Soul Pit per-run) without monkey-patching getById.
ExpeditionConfig.TransientById = ExpeditionConfig.TransientById or {}

function ExpeditionConfig.setTransient(id, entry)
	if id == nil or type(entry) ~= "table" then
		return
	end
	ExpeditionConfig.TransientById[tostring(id)] = entry
end

function ExpeditionConfig.clearTransient(id)
	if id == nil then
		return
	end
	ExpeditionConfig.TransientById[tostring(id)] = nil
end

function ExpeditionConfig.getById(id, role)
	if id == nil then
		return nil
	end
	local key = tostring(id)
	local transient = ExpeditionConfig.TransientById[key]
	if transient then
		return transient
	end
	-- Hunt ids are subarea numbers; boss ids are bossRaceId numbers.
	-- The same number can appear once per role (e.g. hunt 46 vs Black Knight 46).
	local wantRole = nil
	if role == "boss" or role == "monster" or role == "arena" then
		wantRole = role
	end
	local fallback = nil
	for _, entry in ipairs(ExpeditionConfig.Catalog) do
		if entry.id == id or tostring(entry.id) == key then
			local entryRole = entry.role
			if entryRole ~= "boss" and entryRole ~= "monster" and entryRole ~= "arena" then
				entryRole = entry.kind == "boss" and "boss" or "monster"
			end
			if wantRole then
				if entryRole == wantRole then
					return entry
				end
				if not fallback then
					fallback = entry
				end
			else
				return entry
			end
		end
	end
	return fallback
end

--- Raid content role from generated map (scripts/raids/bosses vs monsters).
function ExpeditionConfig.raidRole(raidId)
	if type(raidId) ~= "string" or raidId == "" then
		return "monster"
	end
	local role = ExpeditionConfig.RaidRoles and ExpeditionConfig.RaidRoles[raidId]
	if role == "boss" or role == "monster" then
		return role
	end
	return "monster"
end

--- Monster type name for Game.createMonster from race id / bossRaceId.
--- Resolution order (fallbackName is optional — raceId-only callers are valid):
---   1) CreatureInfo by creatureId (silent; preferred for raids)
---   2) MonsterType(creatureId) when the id is a bestiary race id
---   3) CreatureInfo / MonsterType via fallbackName (skipped when fallback is a
---      raid display label and a numeric race id was already tried)
function ExpeditionConfig.monsterNameByCreatureId(creatureId, fallbackName)
	local id = tonumber(creatureId)

	local info = CreatureInfo and CreatureInfo.getByCreatureId and CreatureInfo.getByCreatureId(id or creatureId)
	if info and type(info.name) == "string" and info.name ~= "" then
		return info.name
	end

	if id and id > 0 then
		local mType = MonsterType(id)
		if mType then
			return mType:name()
		end
	end

	if type(fallbackName) ~= "string" or fallbackName == "" then
		return nil
	end

	local byName = CreatureInfo and CreatureInfo.get and CreatureInfo.get(fallbackName)
	if byName and type(byName.name) == "string" and byName.name ~= "" then
		return byName.name
	end

	-- With a race id, skip engine name lookup — fallback is often a raid label
	-- ("Abdendriel Theevileye"), not a MonsterType name.
	if id and id > 0 then
		return nil
	end

	local mType = MonsterType(fallbackName)
	if mType then
		return mType:name()
	end
	return nil
end

--- Crystal boss.cooldown duration (same key as BossLever / levers).
function ExpeditionConfig.bossCooldownDurationSec()
	local duration = 20 * 60 * 60
	if configManager and configKeys and configKeys.BOSS_DEFAULT_TIME_TO_FIGHT_AGAIN then
		local n = configManager.getNumber(configKeys.BOSS_DEFAULT_TIME_TO_FIGHT_AGAIN)
		if type(n) == "number" and n > 0 then
			duration = n
		end
	end
	return duration
end

--- Lure for a creature density count (persisted snapshots without a lure).
function ExpeditionConfig.lureFromDensity(density)
	local n = math.floor(tonumber(density) or 0)
	if n < 1 then
		return CavebotConfig.LURE_DEFAULT
	end
	return n
end

local caveRouteCache = setmetatable({}, { __mode = "k" })

local function catalogPoint(p)
	local x, y, z = tonumber(p and p.x), tonumber(p and p.y), tonumber(p and p.z)
	if x and y and z then
		return { x = x, y = y, z = z }
	end
	return nil
end

--- Cave route of a monster hunt, parsed once per catalog entry:
--- `{ lure, entry = {pt...}, waypoints = {pt + hold...}, stationary }`.
--- `hold` marks generated spawn cluster stands (the walker clears the screen there).
--- Waypoints wrap (last → first) and may repeat tiles (dead-end legs walked in and
--- back). `entry` is walked once from the landing tile to waypoints[1]. Hunts without
--- a cave block get a single spot on `center`.
function ExpeditionConfig.caveRoute(catalog)
	if type(catalog) ~= "table" then
		return nil
	end
	local cached = caveRouteCache[catalog]
	if cached then
		return cached
	end
	local cave = type(catalog.cave) == "table" and catalog.cave or {}
	local waypoints = {}
	for _, w in ipairs(cave.waypoints or {}) do
		local p = catalogPoint(w)
		if p then
			p.hold = w.hold == true
			waypoints[#waypoints + 1] = p
		end
	end
	if #waypoints == 0 then
		local c = catalogPoint(catalog.center)
		if not c then
			return nil
		end
		c.hold = true
		waypoints[1] = c
	end
	local entry = {}
	for _, w in ipairs(cave.entry or {}) do
		local p = catalogPoint(w)
		if p then
			entry[#entry + 1] = p
		end
	end
	local lure = math.floor(tonumber(cave.lure) or tonumber(catalog.lureMax) or 0)
	local route = {
		lure = lure > 0 and lure or CavebotConfig.LURE_DEFAULT,
		entry = entry,
		waypoints = waypoints,
		stationary = #waypoints <= 1,
	}
	caveRouteCache[catalog] = route
	return route
end

--- Evenly sampled points of `list` (at most `cap`, first always kept).
local function samplePoints(list, cap)
	local out = {}
	local n = #list
	local step = math.max(1, n / cap)
	local i = 1
	while i <= n and #out < cap do
		local p = list[math.floor(i)]
		out[#out + 1] = { x = p.x, y = p.y, z = p.z }
		i = i + step
	end
	return out
end

--- Client minimap preview of a cave route: hold pins and the (closed) walk.
function ExpeditionConfig.cavePreview(route)
	if not route then
		return nil, nil
	end
	local holds = {}
	for _, w in ipairs(route.waypoints) do
		if w.hold then
			holds[#holds + 1] = w
		end
	end
	return samplePoints(holds, 8), samplePoints(route.waypoints, 24)
end

--- Boss lever timeToDefeat (Crystal bossDefaultTimeToDefeat), in seconds.
function ExpeditionConfig.bossTimeToDefeatSec(lever)
	if lever and tonumber(lever.timeToDefeat) and lever.timeToDefeat > 0 then
		return math.floor(lever.timeToDefeat)
	end
	local duration = tonumber(ExpeditionConfig.BOSS_TIME_TO_DEFEAT_SEC) or (20 * 60)
	if configManager and configKeys and configKeys.BOSS_DEFAULT_TIME_TO_DEFEAT then
		local n = configManager.getNumber(configKeys.BOSS_DEFAULT_TIME_TO_DEFEAT)
		if type(n) == "number" and n > 0 then
			duration = n
		end
	end
	return math.max(1, math.floor(duration))
end

--- Raid instance despawn: raids.xml interval2 (minutes → ms), else Lua minGapBetween, else 24h.
function ExpeditionConfig.raidDespawnMs(raidName, raid)
	if type(raidName) == "string" and raidName ~= "" then
		local fromCatalog = ExpeditionConfig.RaidIntervalsMs and ExpeditionConfig.RaidIntervalsMs[raidName]
		local n = tonumber(fromCatalog)
		if n and n > 0 then
			return math.floor(n)
		end
	end
	if raid and type(raid.minGapBetween) == "number" and raid.minGapBetween > 0 then
		return math.floor(raid.minGapBetween)
	end
	return math.floor(tonumber(ExpeditionConfig.RAID_DESPAWN_FALLBACK_MS) or (24 * 60 * 60 * 1000))
end

--- Resolvable MonsterType name for Player:setBossCooldown / canFightBoss.
function ExpeditionConfig.bossTypeName(catalog)
	if not catalog then
		return nil
	end
	local raceId = tonumber(catalog.creatureId)
	if (not raceId or raceId <= 0) and type(catalog.creatureIds) == "table" then
		raceId = tonumber(catalog.creatureIds[1])
	end
	return ExpeditionConfig.monsterNameByCreatureId(raceId, catalog.name)
end

--- Stock BossLever registered for this boss (arena, arrival, spawn, difficulty); nil when none.
function ExpeditionConfig.bossLever(catalog)
	if not catalog or not BossLever or not BossLever.get then
		return nil
	end
	return BossLever.get(ExpeditionConfig.bossTypeName(catalog)) or BossLever.get(catalog.name)
end

--- Lever boss whose lever opts into the difficulty dialog.
function ExpeditionConfig.bossDifficultyLever(catalog)
	local lever = ExpeditionConfig.bossLever(catalog)
	if lever and BossDifficulty and BossDifficulty.isEnabled(lever) then
		return lever
	end
	return nil
end

--- Occupancy mask (Game.setInstancePrivateFence layout) of the tiles in `positions`,
--- with their sorted floors.
local function occupancyOf(positions)
	local x1, y1, x2, y2 = CombatGeo.bounds(positions)
	local floorSet, floors = {}, {}
	for _, p in ipairs(positions) do
		if not floorSet[p.z] then
			floorSet[p.z] = true
			floors[#floors + 1] = p.z
		end
	end
	table.sort(floors)
	local width, height = x2 - x1 + 1, y2 - y1 + 1
	local bytes = {}
	for i = 1, math.ceil(width * height / 8) do
		bytes[i] = 0
	end
	for _, p in ipairs(positions) do
		local i = (p.y - y1) * width + (p.x - x1)
		local b = math.floor(i / 8) + 1
		bytes[b] = bit.bor(bytes[b], bit.lshift(1, i % 8))
	end
	local chars = {}
	for i, byte in ipairs(bytes) do
		chars[i] = string.char(byte)
	end
	local occupancy = {
		originX = x1,
		originY = y1,
		width = width,
		height = height,
		bits = table.concat(chars),
		contains = CombatGeo.maskContains,
	}
	return occupancy, floors
end

--- Private fence of a lever fight: every tile of the lever's zone, i.e. the boss room plus
--- whatever the stock scripts add to it (stage rooms the party arrives in first).
function ExpeditionConfig.bossLeverInstanceSpec(catalog, lever)
	local arrival = lever and lever:arrival(1)
	local positions = lever and lever:getZone():getPositions()
	if not arrival or type(positions) ~= "table" or #positions == 0 then
		return nil
	end
	local occupancy, floors = occupancyOf(positions)
	return {
		region = catalog.region or catalog.id,
		center = { x = arrival.x, y = arrival.y, z = arrival.z },
		entry = { x = arrival.x, y = arrival.y, z = arrival.z },
		boundary = { x = occupancy.originX, y = occupancy.originY, w = occupancy.width, h = occupancy.height, z = arrival.z },
		occupancy = occupancy,
		floors = floors,
	}
end

--- Prefer catalog.encounter (access-based); bosstiaryClass is display-only.
function ExpeditionConfig.bossEncounter(catalog)
	if not catalog then
		return "lever"
	end
	local encounter = catalog.encounter
	if encounter == "solo" or encounter == "lever" then
		return encounter
	end
	local class = catalog.bosstiaryClass
	if class == "Bane" then
		return "solo"
	end
	if class == "Archfoe" or class == "Nemesis" then
		return "lever"
	end
	return "lever"
end

function ExpeditionConfig.isSoloBoss(catalog)
	return ExpeditionConfig.bossEncounter(catalog) == "solo"
end

function ExpeditionConfig.formatBossCooldownRemaining(remainingSec)
	remainingSec = math.max(0, math.floor(tonumber(remainingSec) or 0))
	local hours = math.floor(remainingSec / 3600)
	local minutes = math.floor((remainingSec % 3600) / 60)
	if hours > 0 then
		return string.format("%dh %02dm", hours, minutes)
	end
	if minutes > 0 then
		return string.format("%dm", minutes)
	end
	return string.format("%ds", remainingSec)
end

--- Longest boss cooldown among `members`: remainingSec, blockerPlayer (0, nil when all can fight).
function ExpeditionConfig.partyBossCooldown(members, bossName)
	local remaining, blocker = 0, nil
	for _, member in ipairs(members or {}) do
		if member and PzTeleport.isGod(member) then
			-- GOD may re-enter any boss regardless of lever cooldown.
		elseif member and member.canFightBoss and not member:canFightBoss(bossName) then
			local untilTs = 0
			if member.getBossCooldown then
				untilTs = tonumber(member:getBossCooldown(bossName)) or 0
			end
			local left = math.max(0, untilTs - os.time())
			if not blocker or left > remaining then
				remaining, blocker = left, member
			end
		end
	end
	return remaining, blocker
end

--- Returns ok, blockerPlayer, remainingSec, errorMessage.
function ExpeditionConfig.partyCanFightBoss(members, bossName)
	if type(bossName) ~= "string" or bossName == "" then
		return false, nil, 0, "Unknown boss."
	end
	if type(members) ~= "table" then
		return false, nil, 0, "No team members."
	end
	local remaining, blocker = ExpeditionConfig.partyBossCooldown(members, bossName)
	if blocker then
		return false,
			blocker,
			remaining,
			string.format(
				"%s must wait %s to face %s again.",
				blocker:getName(),
				ExpeditionConfig.formatBossCooldownRemaining(remaining),
				bossName
			)
	end
	return true, nil, 0, nil
end

function ExpeditionConfig.markBossAttempt(player, bossName)
	if not player or type(bossName) ~= "string" or bossName == "" then
		return false
	end
	local store = player.kv and player:kv()
	if not store then
		return false
	end
	store:set(ExpeditionConfig.KV_BOSS_ATTEMPT, bossName)
	return true
end

function ExpeditionConfig.clearBossAttempt(player)
	if not player or not player.kv then
		return false
	end
	local store = player:kv()
	if store then
		store:remove(ExpeditionConfig.KV_BOSS_ATTEMPT)
	end
	return true
end

function ExpeditionConfig.clearBossCooldown(players, bossName)
	if type(bossName) ~= "string" or bossName == "" or type(players) ~= "table" then
		return false
	end
	for _, player in ipairs(players) do
		if player and PzTeleport.isGod(player) then
			-- GOD ignores cooldown.
		elseif player and player.setBossCooldown then
			player:setBossCooldown(bossName, 0)
			if player.sendBosstiaryCooldownTimer then
				player:sendBosstiaryCooldownTimer()
			end
		end
		ExpeditionConfig.clearBossAttempt(player)
	end
	return true
end

--- Refund expedition boss cooldown when an attempt was interrupted (restart / death).
function ExpeditionConfig.refundBossAttemptIfMarked(player)
	if not player or not player.kv then
		return false
	end
	local store = player:kv()
	if not store or not store.get then
		return false
	end
	local bossName = store:get(ExpeditionConfig.KV_BOSS_ATTEMPT)
	if type(bossName) ~= "string" or bossName == "" then
		return false
	end
	ExpeditionConfig.clearBossCooldown({ player }, bossName)
	return true
end

function ExpeditionConfig.applyBossCooldown(players, bossName)
	if type(bossName) ~= "string" or bossName == "" or type(players) ~= "table" then
		return false
	end
	local untilTs = os.time() + ExpeditionConfig.bossCooldownDurationSec()
	local applied = 0
	for _, player in ipairs(players) do
		if player and PzTeleport.isGod(player) then
			-- Skip cooldown so GOD can re-enter immediately.
		elseif player and player.setBossCooldown then
			player:setBossCooldown(bossName, untilTs)
			ExpeditionConfig.markBossAttempt(player, bossName)
			applied = applied + 1
		end
	end
	return applied > 0
end

--- Race id from a living monster (identity - not the runtime creature id).
function ExpeditionConfig.creatureIdFromMonster(monster)
	if not monster or not monster.getType then
		return nil
	end
	local mType = monster:getType()
	if not mType or not mType.raceId then
		return nil
	end
	local id = mType:raceId()
	if type(id) == "number" and id > 0 then
		return id
	end
	return nil
end

function ExpeditionConfig.catalogForClient(player)
	local out = {}
	for _, entry in ipairs(ExpeditionConfig.Catalog) do
		local include = true
		if entry.exclusiveKitno then
			include = player
				and QuestsKitnoBoss
				and QuestsKitnoBoss.isUnlocked
				and QuestsKitnoBoss.isUnlocked(player, entry.id)
		elseif entry.exclusiveArena then
			include = player and QuestArena and QuestArena.canJoin and select(1, QuestArena.canJoin(player, entry))
		end
		if include then
			local role = entry.role
			if role ~= "boss" and role ~= "monster" and role ~= "arena" then
				role = entry.kind == "boss" and "boss" or "monster"
			end
			-- Client hunt UI only knows boss/monster; arena uses monster chrome + wave.
			if role == "arena" then
				role = "monster"
			end
			local row = {
				id = entry.id,
				kind = "hunt",
				role = role,
				name = entry.name,
				levelMin = entry.levelMin,
				recommendedLevel = entry.recommendedLevel,
				creatureId = entry.creatureId,
				floorOffset = tonumber(entry.floorOffset) or 0,
			}
			local combatPower = tonumber(entry.combatPower)
			if combatPower then
				row.combatPower = combatPower
			end
			if entry.exclusiveKitno then
				row.exclusiveKitno = true
			end
			if entry.exclusiveArena then
				row.exclusiveArena = true
				row.encounter = "solo"
				row.maxPlayers = tonumber(entry.maxPlayers) or 1
				row.minPlayers = tonumber(entry.minPlayers) or 1
			end
			local fid = entry.floorFamilyId
			if type(fid) == "string" and fid ~= "" then
				row.floorFamilyId = fid
				row.floorFamilySize = tonumber(entry.floorFamilySize) or 1
				row.floorFamilyIndex = tonumber(entry.floorFamilyIndex) or 0
			end
			local sig = ExpeditionConfig.catalogCreatureSignature(entry)
			if sig ~= "" then
				row.creatureSignature = sig
			end
			local band = ExpeditionConfig.catalogLevelBand(entry)
			if band ~= "" then
				row.levelBand = band
			end
			if role ~= "boss" then
				if entry._displayRepresentative == true then
					row.displayRepresentative = true
				elseif entry._displayRepresentative == false then
					row.displayRepresentative = false
				end
				if type(entry._displayFloorMembers) == "table" and #entry._displayFloorMembers > 1 then
					row.floorMembers = entry._displayFloorMembers
				end
				if type(entry._displayAlternates) == "table" and #entry._displayAlternates > 0 then
					row.alternates = entry._displayAlternates
				end
			else
				row.displayRepresentative = true
			end
			local creatureIds = entry.creatureIds
			if type(creatureIds) == "table" and #creatureIds > 0 then
				local slim = {}
				local n = math.min(8, #creatureIds)
				for i = 1, n do
					slim[i] = creatureIds[i]
				end
				row.creatureIds = slim
			elseif entry.creatureId then
				row.creatureIds = { entry.creatureId }
			end
			-- Slim creature mix for client hunt-detail looks (id + spawn percent + name).
			-- Names come from CreatureInfo so OTC HuntFinder never falls back to the place title.
			-- Do not copy enrichCreatureMix combat stats; the client uses the hunt-level fields.
			local creatures = entry.creatures
			if type(creatures) == "table" and #creatures > 0 then
				local slimCreatures = {}
				local n = math.min(8, #creatures)
				for i = 1, n do
					local c = creatures[i]
					local cid = c and tonumber(c.creatureId)
					if cid and cid > 0 then
						local crow = {
							creatureId = cid,
							percent = tonumber(c.percent) or 0,
						}
						local amt = tonumber(c.count)
						if amt and amt > 0 then
							crow.count = amt
						end
						local cname = c.name
						if (not cname or cname == "") and CreatureInfo and CreatureInfo.getByCreatureId then
							local info = CreatureInfo.getByCreatureId(cid)
							cname = info and info.name or nil
						end
						if cname and cname ~= "" then
							crow.name = cname
						end
						slimCreatures[#slimCreatures + 1] = crow
					end
				end
				if #slimCreatures > 0 then
					row.creatures = slimCreatures
				end
			end
			if role == "boss" then
				row.bosstiaryClass = entry.bosstiaryClass
				local encounter = ExpeditionConfig.bossEncounter(entry)
				row.encounter = encounter
				local maxPlayers = tonumber(entry.maxPlayers)
				if maxPlayers and maxPlayers > 0 then
					row.maxPlayers = maxPlayers
				elseif encounter == "solo" then
					row.maxPlayers = 1
				else
					row.maxPlayers = 5
				end
				local minPlayers = tonumber(entry.minPlayers)
				if minPlayers and minPlayers > 0 then
					row.minPlayers = minPlayers
				elseif encounter == "solo" then
					row.minPlayers = 1
				end
				local difficultyLever = ExpeditionConfig.bossDifficultyLever(entry)
				if difficultyLever then
					row.bossDifficultyMax = BossDifficulty.max(difficultyLever)
				end
			else
				row.city = entry.city
				local density = tonumber(entry.creatureDensity)
				if density and density > 0 then
					row.creatureDensity = density
				end
				local lureMax = tonumber(entry.lureMax)
				if lureMax and lureMax > 0 then
					row.lureMax = lureMax
				end
			end
			local center = entry.center
			if type(center) == "table" and center.x and center.y then
				row.center = {
					x = tonumber(center.x) or 0,
					y = tonumber(center.y) or 0,
					z = tonumber(center.z) or 7,
				}
			end
			-- Cave route preview for client minimap markers (detail + HUD track).
			if role ~= "boss" then
				row.holds, row.route = ExpeditionConfig.cavePreview(ExpeditionConfig.caveRoute(entry))
			end
			out[#out + 1] = row
		end
	end
	return out
end

--- Catalog paging: at most CATALOG_PAGE_SIZE rows and CATALOG_PAGE_BYTES of encoded
--- rows per extended-opcode JSON blob (the opcode string is capped at 64KB).
ExpeditionConfig.CATALOG_PAGE_SIZE = ExpeditionConfig.CATALOG_PAGE_SIZE or 60
ExpeditionConfig.CATALOG_PAGE_BYTES = ExpeditionConfig.CATALOG_PAGE_BYTES or 48000
