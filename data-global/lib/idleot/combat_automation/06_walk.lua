-- Per-player automation movement, walk primitives (the per-tick driver is 10_movement).
-- Pathfinding: Creature:getPathTo + autoWalk. On stall / blocked walk, drop the
-- pending path and recalculate — same idea as client autowalk repathing.
-- Pending walk-then-act (Use / use-with under idle combat) is preserved so echo
-- portal / tame FABs can finish walking adjacent. Client walk / follow input (manual
-- control, see `isManual`) suspends all of it until the player stops.

CombatAutomationMovement = CombatAutomationMovement or {}
--- File-local helpers shared by the movement files (06_walk .. 10_movement).
MOVE_PRIV = MOVE_PRIV or {}

local lastQueuedWalkById = {}
local lastPathFailLogById = {}
--- Last getPathTo failure per creature: { key = dest key, at = ms, count = in a row }.
local lastPathFailById = {}

local settings = CombatAutomationConfig
local PATH_MAX_SEARCH = settings.PATH_MAX_SEARCH
local WALK_DEDUPE_MS = 2500
local PATH_FAIL_FRESH_MS = 1500
--- Failures in a row (one per tick) before a destination counts as blocked: a
--- path closed for a moment by a passing creature is not.
local PATH_FAIL_PERSIST = 3

local geo = CombatGeo
local nowMs, sameTile, chebyshev, faceToward = geo.nowMs, geo.sameTile, geo.chebyshev, geo.faceToward
local tileFree, fartherFromLeash = geo.tileFree, geo.fartherFromLeash

local function clearQueuedWalk(creature)
	if creature then
		lastQueuedWalkById[creature:getId()] = nil
	end
end

--- Drop deferred walk-then-act so Creature:autoWalk is not permanently blocked.
local function clearPendingWalkAction(creature)
	if creature and creature.clearWalkTask then
		creature:clearWalkTask()
	end
end

local walkDestKey = geo.posKey

local function dirsForAutoWalkFromGetPathTo(path)
	if type(path) ~= "table" or #path == 0 then
		return nil
	end
	local out = {}
	for i = #path, 1, -1 do
		out[#out + 1] = path[i]
	end
	return out
end

local PATH_FAIL_LOG_MS = 5000

--- Rate-limited so the 250ms route walk does not flood when a waypoint is unreachable.
local function logWalkFail(creature, dest, reason, extra)
	if not logger or not logger.warn then
		return
	end
	local id = creature and creature.getId and creature:getId() or 0
	local key = string.format("%s:%s", tostring(reason), walkDestKey(dest) or "?")
	local now = nowMs()
	local prev = lastPathFailLogById[id]
	if prev and prev.key == key and (now - (prev.at or 0)) < PATH_FAIL_LOG_MS then
		return
	end
	lastPathFailLogById[id] = { key = key, at = now }
	local from = creature and creature.getPosition and creature:getPosition() or nil
	local name = creature and creature.getName and creature:getName() or "?"
	local instanceId = Instance.of(creature)
	logger.warn(
		"[CombatAutomation] {} {} from {} to {} dist={} instance={}{}",
		reason,
		name,
		walkDestKey(from) or "?",
		walkDestKey(dest) or "?",
		chebyshev(from, dest),
		instanceId,
		extra and (" " .. extra) or ""
	)
end

--- Count one more failed path search toward `key` in a row; returns the count.
local function notePathFail(id, key, now)
	local fail = lastPathFailById[id]
	local count = 1
	if fail and fail.key == key and (now - fail.at) <= PATH_FAIL_FRESH_MS then
		count = fail.count + 1
	end
	lastPathFailById[id] = { key = key, at = now, count = count }
	return count
end

local function occupiedByOther(dest, creature)
	local tile = Tile(dest)
	local top = tile and tile:getTopCreature(creature:getInstanceId())
	return top ~= nil and top:getId() ~= creature:getId()
end

--- True when path searches toward `dest` keep finding nothing (PATH_FAIL_PERSIST in
--- a row, the last just now).
function CombatAutomationMovement.walkBlocked(creature, dest)
	if not creature or not dest then
		return false
	end
	local fail = lastPathFailById[creature:getId()]
	return fail ~= nil
		and fail.key == walkDestKey(dest)
		and fail.count >= PATH_FAIL_PERSIST
		and (nowMs() - fail.at) <= PATH_FAIL_FRESH_MS
end

--- Regular engine path only (flags = 0). Soft creature cost + hard PvP blocks apply.
--- `force` = skip dedupe and clear stuck walkTask (stall repath).
--- `ignoreConditions` = autoWalk despite rooted/feared (expedition route walk).
--- `reach` = Chebyshev distance from `dest` that counts as there (default 0:
--- the exact tile), so a creature standing on a waypoint does not block it;
--- `minReach` = closest it may end (default 0), for rings around a spot.
--- An exact destination another creature stands on is not searched: it counts as a
--- failed search (see `walkBlocked`) without a warning.
--- `quiet` = never warn (halt tile walks: the caller repicks on `walkBlocked`).
function CombatAutomationMovement.queueWalkToward(creature, dest, force, ignoreConditions, reach, quiet, minReach)
	if not creature or not dest or not creature.autoWalk then
		return false
	end
	local ppos = creature:getPosition()
	if not ppos then
		return false
	end
	reach = math.max(0, math.floor(tonumber(reach) or 0))
	minReach = math.min(reach, math.max(0, math.floor(tonumber(minReach) or 0)))
	local dist = chebyshev(ppos, dest)
	if dist >= minReach and dist <= reach then
		clearQueuedWalk(creature)
		return true
	end
	local id = creature:getId()
	local key = walkDestKey(dest)
	local prev = lastQueuedWalkById[id]
	local now = nowMs()
	local pkey = walkDestKey(ppos)
	local stuck = prev and prev.key == key and prev.posKey and prev.posKey == pkey and (now - (prev.at or 0)) >= settings.STALL_REPATH_MS
	if not force and prev and prev.key == key then
		if not stuck and (now - (prev.at or 0)) < WALK_DEDUPE_MS then
			return true
		end
	end

	-- A pending walk-then-act (Use / use-with) owns the path until it fires or fails.
	-- Do not clear it for soft repaths — that broke echo portal / tame under idle combat.
	if creature.hasWalkTask and creature:hasWalkTask() then
		if not force and not ignoreConditions then
			return true
		end
		-- Relocate / explicit force may supersede a deferred Use.
		clearPendingWalkAction(creature)
		clearQueuedWalk(creature)
	elseif force or stuck then
		clearQueuedWalk(creature)
	end

	local maxSearch = PATH_MAX_SEARCH
	local minDist, maxDist = minReach, reach
	if maxDist == 0 and occupiedByOther(dest, creature) then
		notePathFail(id, key, now)
		clearQueuedWalk(creature)
		return false
	end
	local path = dirsForAutoWalkFromGetPathTo(creature:getPathTo(dest, minDist, maxDist, true, false, maxSearch))
	if type(path) ~= "table" or #path == 0 then
		local count = notePathFail(id, key, now)
		-- Stance / follow retries (BLOCKPATH, etc.) are expected every tick. Only a
		-- route walk that stays blocked is worth a warning.
		if ignoreConditions and not quiet and count == PATH_FAIL_PERSIST then
			logWalkFail(
				creature,
				dest,
				"getPathTo failed",
				string.format("search=%d minDist=%d maxDist=%d relocate=true", maxSearch, minDist, maxDist)
			)
		end
		clearQueuedWalk(creature)
		return false
	end
	lastPathFailById[id] = nil

	local skipConds = (force or stuck or ignoreConditions) and true or false
	if creature:autoWalk(path, 0, skipConds, true) == true then
		lastQueuedWalkById[id] = { key = key, at = now, posKey = pkey }
		return true
	end

	-- Walk refused (e.g. walkTask raced in): clear and retry once with force.
	if creature.hasWalkTask and creature:hasWalkTask() then
		clearPendingWalkAction(creature)
		if creature:autoWalk(path, 0, true, true) == true then
			lastQueuedWalkById[id] = { key = key, at = now, posKey = pkey }
			return true
		end
	end

	if ignoreConditions and not quiet then
		logWalkFail(creature, dest, "autoWalk refused", string.format("steps=%d relocate=true", #path))
	end
	clearQueuedWalk(creature)
	return false
end
--- Client walk / follow input owns this player's movement (expedition idle combat):
--- a manual walk or follow is running, or the last manual step is under
--- MANUAL_CONTROL_MS old. With `sinceMs`, only steps taken after it
--- count (an errand ignores the steps that came before it).
function CombatAutomationMovement.isManual(player, sinceMs)
	if not player or not player.isManualControl then
		return false
	end
	local graceMs = settings.MANUAL_CONTROL_MS
	if sinceMs then
		graceMs = math.max(0, math.min(graceMs, nowMs() - sinceMs))
	end
	return player:isManualControl(graceMs) == true
end
local isManual = CombatAutomationMovement.isManual

--- Never drops a follow the player started (manual control).
local function clearFollowIfAny(player)
	if player and player.getFollowCreature and player:getFollowCreature() and not isManual(player) then
		player:setFollowCreature(nil)
	end
end


local function autoEnabled(config)
	return type(config) == "table"
		and type(config.autoTarget) == "table"
		and config.autoTarget.enabled == true
end

--- Walk toward a moving creature: repath at most every CREATURE_REPATH_MS (or when
--- stuck) so autoWalk is not restarted every tick while the target moves.
local CREATURE_REPATH_MS = 1000
local function walkTowardCreature(player, creature, reach, maxSearch)
	if not player or not creature then
		return false
	end
	local ppos = player:getPosition()
	local cpos = creature:getPosition()
	if not ppos or not cpos or ppos.z ~= cpos.z then
		return false
	end
	reach = math.max(1, math.floor(tonumber(reach) or 1))
	if chebyshev(ppos, cpos) <= reach then
		clearQueuedWalk(player)
		return true
	end
	local id = player:getId()
	local key = "creature:" .. tostring(creature:getId())
	local prev = lastQueuedWalkById[id]
	local now = nowMs()
	local pkey = walkDestKey(ppos)
	local stuck = prev and prev.key == key and prev.posKey == pkey and (now - (prev.at or 0)) >= settings.STALL_REPATH_MS
	if prev and prev.key == key and not stuck and (now - (prev.at or 0)) < CREATURE_REPATH_MS then
		return true
	end
	local path = dirsForAutoWalkFromGetPathTo(player:getPathTo(cpos, 0, reach, true, false, tonumber(maxSearch) or PATH_MAX_SEARCH))
	if type(path) ~= "table" or #path == 0 then
		return false
	end
	if stuck and player.clearWalkTask then
		player:clearWalkTask()
	end
	if player:autoWalk(path, 0, stuck and true or false, true) == true then
		lastQueuedWalkById[id] = { key = key, at = now, posKey = pkey }
		return true
	end
	return false
end

local function sightClear(player, from, to)
	if not from.isSightClear then
		return true
	end
	return from:isSightClear(to, true, Instance.of(player))
end

--- Reposition attempts (danger dodges, formation steps) at most this often.
local ADJUST_THROTTLE_MS = 500

local function throttled(state, field, ms)
	if not state then
		return false
	end
	local now = nowMs()
	if now - (state[field] or 0) < ms then
		return true
	end
	state[field] = now
	return false
end

local function stepTo(player, dest)
	clearFollowIfAny(player)
	return CombatAutomationMovement.queueWalkToward(player, dest, true)
end

MOVE_PRIV.throttled = throttled
MOVE_PRIV.ADJUST_THROTTLE_MS = ADJUST_THROTTLE_MS
MOVE_PRIV.stepTo = stepTo
MOVE_PRIV.sightClear = sightClear
MOVE_PRIV.clearFollowIfAny = clearFollowIfAny
MOVE_PRIV.clearQueuedWalk = clearQueuedWalk
MOVE_PRIV.autoEnabled = autoEnabled
MOVE_PRIV.clearPendingWalkAction = clearPendingWalkAction
MOVE_PRIV.walkTowardCreature = walkTowardCreature
