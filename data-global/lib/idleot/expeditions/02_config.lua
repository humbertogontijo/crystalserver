ExpeditionConfig = ExpeditionConfig or {}

ExpeditionConfig.OPCODE = 113

-- Runtime storage (not DB storages.xml) for expedition flags.
ExpeditionConfig.STORAGE_ACTIVE = 910001
ExpeditionConfig.STORAGE_EXPEDITION_ID = 910002
ExpeditionConfig.STORAGE_RETURN_X = 910003
ExpeditionConfig.STORAGE_RETURN_Y = 910004
ExpeditionConfig.STORAGE_RETURN_Z = 910005
ExpeditionConfig.STORAGE_SLOT = 910006

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

ExpeditionConfig.SUBAREA_DIR = "tibia/subareas"
ExpeditionConfig.AI_TICK_MS = 250
-- Chebyshev distance: hunt monsters farther than this from the party anchor walk toward it
-- (keeps echo raids / stray spawns in the viewport).
ExpeditionConfig.MONSTER_ANCHOR_LEASH_SQM = 6
-- Repath formation slots when stuck on the same tile (ms); avoids multi-second walk dedupe pauses.
ExpeditionConfig.FORMATION_REPATH_MS = 400
-- Aliases to CombatAutomationConfig (owned by lib/idleot/combat_automation/).
ExpeditionConfig.AUTOMATION_TICK_MS = CombatAutomationConfig and CombatAutomationConfig.TICK_MS or 250
ExpeditionConfig.AUTOMATION_POTION_EXHAUST_MS = CombatAutomationConfig and CombatAutomationConfig.POTION_EXHAUST_MS or 1000
ExpeditionConfig.AUTOMATION_RUNE_EXHAUST_MS = CombatAutomationConfig and CombatAutomationConfig.RUNE_EXHAUST_MS or 2000
ExpeditionConfig.AUTOMATION_SPELL_EXHAUST_MS = CombatAutomationConfig and CombatAutomationConfig.SPELL_EXHAUST_MS or 2000
ExpeditionConfig.SpellCooldownMsByWords = CombatAutomationConfig and CombatAutomationConfig.SpellCooldownMsByWords or {}
ExpeditionConfig.RuneWordsByTypeId = CombatAutomationConfig and CombatAutomationConfig.RuneWordsByTypeId or {}
-- Voluntary leave: server delays eject this many seconds (client shows the same countdown).
ExpeditionConfig.LEAVE_COUNTDOWN_SEC = 5
-- Shared team-accept ready check (host + invitees). Expiry cancels the waiting lobby.
ExpeditionConfig.TEAM_ACCEPT_TIMEOUT_SEC = 45
-- Map-spawn lure hunts (ExpeditionWaves.tickLure). Instance spawns come from the
-- world spawn XML; the anchor pulls monsters within PULL_RING whose path to it is
-- at most PULL_STEPS. Keep PULL_RING / PULL_STEPS in sync with the asset pipeline
-- (hunt_types.py) so presumed hold lure matches what the runtime pulls.
ExpeditionConfig.PULL_RING = 8
ExpeditionConfig.PULL_STEPS = 8
-- A* checks per tick for new pull candidates (hot path cap).
ExpeditionConfig.PULL_PATHS_PER_TICK = 6
-- Engaged monsters farther than this from the anchor go back to their spawn.
ExpeditionConfig.RELEASE_RADIUS = 18
-- Engaged monsters that make no progress toward the party for this long are released.
ExpeditionConfig.PULL_STALL_MS = 8000
-- Anchor within this Chebyshev distance of the hold counts as arrived.
ExpeditionConfig.HOLD_ARRIVE_RADIUS = 1
-- Anchor stops walking while engaged >= lure * OVERWHELM_FACTOR; resumes at <= lure.
ExpeditionConfig.OVERWHELM_FACTOR = 2
-- No progress toward the current route waypoint / hold for this long skips it.
ExpeditionConfig.RELOCATE_STALL_MS = 12000
-- Familiar-style catch-up (Creature::checkSummonMove): match anchor speed + soft surplus when behind,
-- teleport at 15 SQM. Surplus ramps with lag (not a flat haste); this is the max at near-teleport range.
-- Teleport yank when companions fall too far behind (no speed overrides).
ExpeditionConfig.CATCH_UP_TELEPORT_SQM = 15
-- Path search radius (Chebyshev) for hold walks. Non-zero uses Crystal's
-- getPathMatchingCond (no 100-node hard stop). 0 = unrestricted but capped at 100 nodes.
ExpeditionConfig.HOLD_PATH_MAX = 128
-- Classic Tibia spawn flash (matches SpawnMonster::NONBLOCKABLE_SPAWN_MONSTER_INTERVAL).
ExpeditionConfig.PRE_SPAWN_FLASHES = 3
ExpeditionConfig.PRE_SPAWN_INTERVAL_MS = 1400
-- After instance teleport, wait before AI/spawn so OTC finishes map description.
ExpeditionConfig.ENTRY_CLIENT_SYNC_MS = 500
ExpeditionConfig.FALLBACK_GROUND_ID = 4526 -- grass
-- Player-selectable spawn intensity (creatures per wave). Discrete steps only.
ExpeditionConfig.LURE_VALUES = { 1, 2, 4, 6, 8, 12, 16 }
ExpeditionConfig.LURE_MIN = ExpeditionConfig.LURE_VALUES[1]
ExpeditionConfig.LURE_MAX = ExpeditionConfig.LURE_VALUES[#ExpeditionConfig.LURE_VALUES]
ExpeditionConfig.LURE_DEFAULT = 1

--- Exact match against LURE_VALUES (or legacy min..max when values missing).
--- Optional `lureMax` caps allowed values for a hunt's creature density.
function ExpeditionConfig.isValidLure(value, lureMax)
	local n = math.floor(tonumber(value) or 0)
	local values = ExpeditionConfig.lureValuesUpTo(lureMax)
	if type(values) == "table" and #values > 0 then
		for _, v in ipairs(values) do
			if v == n then
				return true
			end
		end
		return false
	end
	local lureMin = ExpeditionConfig.LURE_MIN or 1
	local hi = math.floor(tonumber(lureMax) or ExpeditionConfig.LURE_MAX or lureMin)
	return n >= lureMin and n <= hi
end

--- Allowed lure steps not exceeding `lureMax` (defaults to global max).
function ExpeditionConfig.lureValuesUpTo(lureMax)
	local values = ExpeditionConfig.LURE_VALUES
	if type(values) ~= "table" or #values == 0 then
		return values
	end
	local hi = math.floor(tonumber(lureMax) or ExpeditionConfig.LURE_MAX or values[#values])
	local out = {}
	for _, v in ipairs(values) do
		if v <= hi then
			out[#out + 1] = v
		end
	end
	if #out == 0 then
		out[1] = values[1]
	end
	return out
end

--- Snap to nearest allowed lure (for join / wave count).
--- Optional `lureMax` caps the allowed set (per-hunt creature density).
function ExpeditionConfig.normalizeLure(value, lureMax)
	local values = ExpeditionConfig.lureValuesUpTo(lureMax)
	local fallback = ExpeditionConfig.LURE_DEFAULT or ExpeditionConfig.LURE_MIN or 1
	if type(values) == "table" and #values > 0 then
		fallback = values[1]
	end
	local n = math.floor(tonumber(value) or fallback)
	if type(values) ~= "table" or #values == 0 then
		local lureMin = ExpeditionConfig.LURE_MIN or 1
		local hi = math.floor(tonumber(lureMax) or ExpeditionConfig.LURE_MAX or lureMin)
		if n < lureMin then
			return lureMin
		elseif n > hi then
			return hi
		end
		return n
	end
	local best = values[1]
	local bestDist = math.abs(n - best)
	for i = 2, #values do
		local v = values[i]
		if v == n then
			return n
		end
		local d = math.abs(n - v)
		if d < bestDist then
			best = v
			bestDist = d
		end
	end
	return best
end

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

-- Expedition stance roles (auto from vocation for boss + raid; Chebyshev distance for close/ranged).
-- Melee remains for knight (locked); choosable vocations pick close and/or ranged only.
ExpeditionConfig.STANCE_ROLES = { melee = true, close = true, ranged = true }
ExpeditionConfig.STANCE_DISTANCE = { melee = 1, close = 1, ranged = 3 }
-- Single ranged hold distance (formation / creature-stance Chebyshev).
ExpeditionConfig.RANGED_DISTANCE_DEFAULT = 3
ExpeditionConfig.RANGED_DISTANCE_OPTIONS = { 3 }
-- Post-clear loot window before eject/sweep (boss, hunt wave-limit, raid).
ExpeditionConfig.LOOT_GRACE_MS = 5000
-- Fallback when configKeys.BOSS_DEFAULT_TIME_TO_DEFEAT is unavailable (lever timeout).
ExpeditionConfig.BOSS_TIME_TO_DEFEAT_SEC = 20 * 60
-- Fallback when raids.xml interval2 is missing (matches typical interval2=1440).
ExpeditionConfig.RAID_DESPAWN_FALLBACK_MS = 24 * 60 * 60 * 1000
-- When player HP% is below this, switch from anchor formation to creature-stance positioning.
-- Raids always use creature stance (never anchor formation).
ExpeditionConfig.POSITION_CRITICAL_HP_PERCENT = 30

--- True when current HP is below the formation critical threshold.
function ExpeditionConfig.isPositionCritical(player)
	if not player then
		return false
	end
	local maxHp = player:getMaxHealth()
	if not maxHp or maxHp <= 0 then
		return false
	end
	local threshold = tonumber(ExpeditionConfig.POSITION_CRITICAL_HP_PERCENT) or 30
	local pct = (player:getHealth() / maxHp) * 100
	return pct < threshold
end

--- Stance roles a vocation may pick in the AUTO stance modal.
--- Knights stay melee-locked (no chooser). Monks: close. Paladins: close or ranged. Mages: ranged.
function ExpeditionConfig.allowedStancesForPlayer(player)
	local key = ""
	if CombatAutomationCatalog and CombatAutomationCatalog.baseVocationKey then
		key = CombatAutomationCatalog.baseVocationKey(player) or ""
	end
	if key == "monk" then
		return { "close" }
	end
	if key == "paladin" then
		return { "close", "ranged" }
	end
	return { ExpeditionConfig.stanceForPlayer(player) or "melee" }
end

--- True when vocation may choose among multiple positioning stances.
function ExpeditionConfig.stanceRoleConfigurable(player)
	local allowed = ExpeditionConfig.allowedStancesForPlayer(player)
	if #allowed > 1 then
		return true
	end
	return allowed[1] == "ranged"
end

--- Validate stance + rangedDistance against vocation; returns role, rangedDistance.
--- Legacy melee picks on monk/paladin migrate to close; legacy ranged 4 → 3.
function ExpeditionConfig.normalizeStanceForPlayer(player, stance, rangedDistance)
	local allowed = ExpeditionConfig.allowedStancesForPlayer(player)
	local default = ExpeditionConfig.stanceForPlayer(player) or "melee"
	local role = tostring(stance or default)
	-- Choosable vocations no longer offer melee; treat legacy melee as close.
	if role == "melee" then
		local key = ""
		if CombatAutomationCatalog and CombatAutomationCatalog.baseVocationKey then
			key = CombatAutomationCatalog.baseVocationKey(player) or ""
		end
		if key == "monk" or key == "paladin" then
			role = "close"
		end
	end
	local ok = false
	for _, entry in ipairs(allowed) do
		if entry == role then
			ok = true
			break
		end
	end
	if not ok then
		role = default
	end
	local rd = tonumber(ExpeditionConfig.RANGED_DISTANCE_DEFAULT) or 3
	if role == "ranged" then
		rd = ExpeditionConfig.normalizeRangedDistance(rangedDistance)
	end
	return role, rd
end

--- Persisted automation stance for a player (vocation-validated).
function ExpeditionConfig.configuredStanceForPlayer(player)
	if CombatAutomationStore and CombatAutomationStore.getConfig then
		local cfg = CombatAutomationStore.getConfig(player)
		local at = cfg and cfg.autoTarget
		if at then
			return ExpeditionConfig.normalizeStanceForPlayer(player, at.stance, at.rangedDistance)
		end
	end
	return ExpeditionConfig.normalizeStanceForPlayer(player, nil, nil)
end

--- Normalize rangedDistance to the single supported value (legacy 4 collapses to 3).
function ExpeditionConfig.normalizeRangedDistance(value)
	local default = tonumber(ExpeditionConfig.RANGED_DISTANCE_DEFAULT) or 3
	local n = math.floor(tonumber(value) or 0)
	if n == default then
		return default
	end
	-- Accept any positive legacy value by collapsing to the sole option.
	if n > 0 then
		return default
	end
	return default
end

--- Chebyshev hold distance for a stance role (ranged vocations may override via automation config).
function ExpeditionConfig.stanceDistanceFor(role, rangedDistance)
	local map = ExpeditionConfig.STANCE_DISTANCE or {}
	if role == "ranged" then
		return ExpeditionConfig.normalizeRangedDistance(rangedDistance or map.ranged)
	end
	return map[role] or 1
end

--- Map player vocation → default expedition stance.
--- Druid/Sorcerer (+promoted): ranged; Paladin (+promoted): close; others: melee.
--- Monks: close only; paladins: close or ranged; knights: melee locked.
function ExpeditionConfig.stanceForPlayer(player)
	if not player then
		return "melee"
	end
	local vocation = player:getVocation()
	if not vocation then
		return "melee"
	end
	local baseId = vocation:getBaseId()
	if baseId == VOCATION.BASE_ID.SORCERER or baseId == VOCATION.BASE_ID.DRUID then
		return "ranged"
	end
	if baseId == VOCATION.BASE_ID.PALADIN then
		return "close"
	end
	if baseId == VOCATION.BASE_ID.MONK then
		return "close"
	end
	return "melee"
end

-- Party anchor: lower rank wins (knight → paladin → monk → anyone else).
-- Used for spawn center + non-anchor cardinal positioning (not raids).
ExpeditionConfig.ANCHOR_VOCATION_RANK = {
	knight = 1,
	paladin = 2,
	monk = 3,
	other = 4,
}

--- Vocation priority rank for anchor selection (lower = preferred).
function ExpeditionConfig.anchorVocationRank(player)
	if not player then
		return ExpeditionConfig.ANCHOR_VOCATION_RANK.other
	end
	local vocation = player:getVocation()
	if not vocation then
		return ExpeditionConfig.ANCHOR_VOCATION_RANK.other
	end
	local baseId = vocation:getBaseId()
	if baseId == VOCATION.BASE_ID.KNIGHT then
		return ExpeditionConfig.ANCHOR_VOCATION_RANK.knight
	end
	if baseId == VOCATION.BASE_ID.PALADIN then
		return ExpeditionConfig.ANCHOR_VOCATION_RANK.paladin
	end
	if VOCATION.BASE_ID.MONK and baseId == VOCATION.BASE_ID.MONK then
		return ExpeditionConfig.ANCHOR_VOCATION_RANK.monk
	end
	return ExpeditionConfig.ANCHOR_VOCATION_RANK.other
end

--- Living members eligible to be the party anchor (online, HP > 0, not dead-flagged).
local function livingAnchorCandidates(session)
	local out = {}
	if not session then
		return out
	end
	local dead = session.deadPlayerIds
	local ids = {}
	if type(session.playerIds) == "table" and #session.playerIds > 0 then
		ids = session.playerIds
	elseif session.playerId then
		ids = { session.playerId }
	end
	for _, id in ipairs(ids) do
		if not (dead and dead[id]) then
			local p = Player(id)
			if p and p:getHealth() > 0 then
				out[#out + 1] = p
			end
		end
	end
	return out
end

--- Pick session.anchorPlayerId: vocation rank, then highest max HP, then lowest id.
function ExpeditionConfig.pickAnchor(session)
	if not session then
		return nil
	end
	local candidates = livingAnchorCandidates(session)
	if #candidates == 0 then
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

	local best = candidates[1]
	local bestRank = ExpeditionConfig.anchorVocationRank(best)
	local bestHp = best:getMaxHealth() or 0
	local bestId = best:getId()
	for i = 2, #candidates do
		local p = candidates[i]
		local rank = ExpeditionConfig.anchorVocationRank(p)
		local hp = p:getMaxHealth() or 0
		local id = p:getId()
		if rank < bestRank or (rank == bestRank and hp > bestHp) or (rank == bestRank and hp == bestHp and id < bestId) then
			best = p
			bestRank = rank
			bestHp = hp
			bestId = id
		end
	end
	session.anchorPlayerId = bestId
	return bestId
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
ExpeditionConfig.RAID_WATCH_INTERVAL_MS = 2000
ExpeditionConfig.RAID_ARENA_KIND = "raid"
ExpeditionConfig.RAID_JOIN_HINT = "Join via Expeditions → Active raids."
-- How many shared raid instances may run at once (XML + Lua Raid.registry).
ExpeditionConfig.RAID_MAX_CONCURRENT = 2
-- XML import: first-check chance and per-row / per-raid spawn caps (17×17 arena).
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

--- Predefined lure for a hold: catalog `lure`, else floor(creatureDensity), else hunt lureMax.
--- Lure is the density count directly (no 1/2/4/6/8/12/16 snap).
function ExpeditionConfig.lureFromDensity(density)
	local n = math.floor(tonumber(density) or 0)
	if n < 1 then
		return ExpeditionConfig.LURE_DEFAULT or 1
	end
	return n
end

function ExpeditionConfig.holdLure(hold, catalog)
	if type(hold) == "table" then
		local lure = tonumber(hold.lure)
		if lure and lure > 0 then
			return math.max(1, math.floor(lure))
		end
		local dens = tonumber(hold.creatureDensity)
		if dens and dens > 0 then
			return ExpeditionConfig.lureFromDensity(dens)
		end
	end
	local huntMax = catalog and tonumber(catalog.lureMax)
	if huntMax and huntMax > 0 then
		return math.max(1, math.floor(huntMax))
	end
	return ExpeditionConfig.LURE_DEFAULT or 1
end

--- Catalog hold list for monster hunts (team-fit positions). Falls back to center.
--- Each hold keeps `{x,y,z,lure,route}` (lure derived from catalog when missing;
--- `route` = waypoints of the incoming leg from the previous hold, may be nil).
function ExpeditionConfig.catalogPositions(catalog)
	if not catalog then
		return {}
	end
	local positions = catalog.positions
	if type(positions) == "table" and #positions > 0 then
		local out = {}
		for _, p in ipairs(positions) do
			if p and p.x and p.y and p.z then
				local route = nil
				if type(p.route) == "table" and #p.route > 0 then
					route = {}
					for _, wp in ipairs(p.route) do
						if wp.x and wp.y and wp.z then
							route[#route + 1] = { x = wp.x, y = wp.y, z = wp.z }
						end
					end
				end
				out[#out + 1] = {
					x = p.x,
					y = p.y,
					z = p.z,
					lure = ExpeditionConfig.holdLure(p, catalog),
					route = route,
				}
			end
		end
		if #out > 0 then
			return out
		end
	end
	local c = catalog.center
	if c and c.x and c.y and c.z then
		return {
			{
				x = c.x,
				y = c.y,
				z = c.z,
				lure = ExpeditionConfig.holdLure(nil, catalog),
			},
		}
	end
	return {}
end

function ExpeditionConfig.sameHoldTile(a, b)
	if not a or not b then
		return false
	end
	local ax, ay, az = tonumber(a.x), tonumber(a.y), tonumber(a.z)
	local bx, by, bz = tonumber(b.x), tonumber(b.y), tonumber(b.z)
	return ax and bx and ax == bx and ay == by and az == bz
end

--- Hold for wave N (1-based, wraps). Wave 0 / nil uses hold 1 (upcoming first wave).
function ExpeditionConfig.holdForWave(catalog, wave)
	local holds = ExpeditionConfig.catalogPositions(catalog)
	if #holds == 0 then
		return nil, 0
	end
	local w = math.max(1, math.floor(tonumber(wave) or 1))
	local idx = ((w - 1) % #holds) + 1
	return holds[idx], idx
end

--- Copy hold tile + lure from session.wave onto the session (wave 0 → hold 1).
function ExpeditionConfig.syncHoldFromWave(session)
	if not session then
		return nil, 0
	end
	local wave = math.floor(tonumber(session.wave) or 0)
	local hold, idx = ExpeditionConfig.holdForWave(session.catalog, wave < 1 and 1 or wave)
	if hold then
		session.holdPos = Position(hold.x, hold.y, hold.z)
		session.lure = tonumber(hold.lure) or ExpeditionConfig.holdLure(hold, session.catalog)
	end
	return hold, idx
end

--- Commit the next wave. Hold tile and lure follow `session.wave`.
--- Returns true when the party should walk to a different hold.
function ExpeditionConfig.advanceWave(session)
	if not session then
		return false
	end
	local prev = session.holdPos
	session.wave = math.floor(tonumber(session.wave) or 0) + 1
	ExpeditionConfig.syncHoldFromWave(session)
	if session.role and session.role ~= "monster" then
		return false
	end
	if not ExpeditionConfig.canRelocateHolds(session.catalog) then
		return false
	end
	return not ExpeditionConfig.sameHoldTile(prev, session.holdPos)
end

--- Active lure for session's current (or upcoming first) hold.
function ExpeditionConfig.sessionHoldLure(session)
	if not session then
		return ExpeditionConfig.LURE_DEFAULT or 1
	end
	local hold = ExpeditionConfig.holdForWave(session.catalog, session.wave)
	if hold then
		return tonumber(hold.lure) or ExpeditionConfig.holdLure(hold, session.catalog)
	end
	return ExpeditionConfig.lureFromDensity(session.catalog and session.catalog.lureMax)
end

--- True when this hunt has enough holds to walk between waves.
function ExpeditionConfig.canRelocateHolds(catalog)
	return #ExpeditionConfig.catalogPositions(catalog) >= 2
end

--- Boss lever timeToDefeat (Crystal bossDefaultTimeToDefeat), in seconds.
function ExpeditionConfig.bossTimeToDefeatSec()
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

--- Returns ok, blockerPlayer, remainingSec, errorMessage.
function ExpeditionConfig.partyCanFightBoss(members, bossName)
	if type(bossName) ~= "string" or bossName == "" then
		return false, nil, 0, "Unknown boss."
	end
	if type(members) ~= "table" then
		return false, nil, 0, "No team members."
	end
	for _, member in ipairs(members) do
		if member and PzTeleport and PzTeleport.isGod and PzTeleport.isGod(member) then
			-- GOD may re-enter any boss regardless of lever cooldown.
		elseif member and member.canFightBoss and not member:canFightBoss(bossName) then
			local untilTs = 0
			if member.getBossCooldown then
				untilTs = tonumber(member:getBossCooldown(bossName)) or 0
			end
			local remaining = math.max(0, untilTs - os.time())
			return false,
				member,
				remaining,
				string.format(
					"%s must wait %s to face %s again.",
					member:getName(),
					ExpeditionConfig.formatBossCooldownRemaining(remaining),
					bossName
				)
		end
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
		if player and PzTeleport and PzTeleport.isGod and PzTeleport.isGod(player) then
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
		if player and PzTeleport and PzTeleport.isGod and PzTeleport.isGod(player) then
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
			-- Team-fit walk stands for client minimap markers (detail + HUD).
			local positions = ExpeditionConfig.catalogPositions(entry)
			if #positions > 0 then
				local slim = {}
				local n = math.min(8, #positions)
				for i = 1, n do
					local p = positions[i]
					slim[i] = {
						x = tonumber(p.x) or 0,
						y = tonumber(p.y) or 0,
						z = tonumber(p.z) or 7,
						lure = tonumber(p.lure) or ExpeditionConfig.holdLure(p, entry),
					}
				end
				row.positions = slim
			end
			out[#out + 1] = row
		end
	end
	return out
end

--- Max catalog entries per extended-opcode JSON blob (keep under ~60KB).
ExpeditionConfig.CATALOG_PAGE_SIZE = ExpeditionConfig.CATALOG_PAGE_SIZE or 60
