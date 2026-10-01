-- Per-player automation movement: hold / follow directives + creature stance.
-- Pathfinding: Creature:getPathTo + autoWalk. On stall / blocked walk, drop the
-- pending path and recalculate — same idea as client autowalk repathing.
-- Pending walk-then-act (Use / use-with under idle combat) is preserved so echo
-- portal / tame FABs can finish walking adjacent.

CombatAutomationMovement = CombatAutomationMovement or {}

local lastQueuedWalkById = {}
local lastPathFailLogById = {}
--- Last getPathTo failure per creature: { key = dest key, at = ms }.
local lastPathFailById = {}
-- Temporary exclusive destinations (discovery POI FAB). Blocks stance/hold from
-- stealing the path under idle combat without unlocking general client autoWalk.
local exclusiveWalkById = {}

local VIEWPORT_X = 8
local VIEWPORT_Y = 6
local PATH_MAX_SEARCH = 128
local WALK_DEDUPE_MS = 2500
local STALL_REPATH_MS = 400
local EXCLUSIVE_WALK_TTL_MS = 20000
local PATH_FAIL_FRESH_MS = 1500
local FOCUS_GRACE_MS = 1000

local function nowMs()
	return os.mtime and os.mtime() or (os.time() * 1000)
end

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

local function walkDestKey(pos)
	if not pos then
		return nil
	end
	return string.format("%d,%d,%d", pos.x, pos.y, pos.z)
end

local function posKey(pos)
	return walkDestKey(pos)
end

local function sameTile(a, b)
	return a and b and a.x == b.x and a.y == b.y and a.z == b.z
end

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

local function chebyshev(a, b)
	if not a or not b then
		return -1
	end
	return math.max(math.abs((a.x or 0) - (b.x or 0)), math.abs((a.y or 0) - (b.y or 0)))
end

--- Rate-limited so relocate's 250ms tick does not flood when a hold is unreachable.
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
	local instanceId = creature and creature.getInstanceId and creature:getInstanceId() or 0
	logger.warn(
		"[CombatAutomation] {} {} from {} to {} dist={} instance={}{}",
		reason,
		name,
		from and string.format("%d,%d,%d", from.x, from.y, from.z) or "?",
		dest and string.format("%d,%d,%d", dest.x, dest.y, dest.z) or "?",
		chebyshev(from, dest),
		instanceId,
		extra and (" " .. extra) or ""
	)
end

--- True when the last path search toward `dest` found nothing, just now.
function CombatAutomationMovement.walkBlocked(creature, dest)
	if not creature or not dest then
		return false
	end
	local fail = lastPathFailById[creature:getId()]
	return fail ~= nil and fail.key == walkDestKey(dest) and (nowMs() - fail.at) <= PATH_FAIL_FRESH_MS
end

--- Regular engine path only (flags = 0). Soft creature cost + hard PvP blocks apply.
--- `force` = skip dedupe and clear stuck walkTask (stall repath).
--- `ignoreConditions` = autoWalk despite rooted/feared (hold-to-hold relocate).
--- `reach` = Chebyshev distance from `dest` that counts as there (default 0:
--- the exact tile), so a creature standing on a waypoint does not block it.
function CombatAutomationMovement.queueWalkToward(creature, dest, force, ignoreConditions, reach)
	if not creature or not dest or not creature.autoWalk then
		return false
	end
	local ppos = creature:getPosition()
	if not ppos then
		return false
	end
	reach = math.max(0, math.floor(tonumber(reach) or 0))
	if sameTile(ppos, dest) or (reach > 0 and ppos.z == dest.z and chebyshev(ppos, dest) <= reach) then
		clearQueuedWalk(creature)
		return true
	end
	local id = creature:getId()
	local key = walkDestKey(dest)
	local prev = lastQueuedWalkById[id]
	local now = nowMs()
	local pkey = posKey(ppos)
	local stuckMs = (ExpeditionConfig and tonumber(ExpeditionConfig.STATE_REPATH_MS)) or STALL_REPATH_MS
	local stuck = prev and prev.key == key and prev.posKey and prev.posKey == pkey and (now - (prev.at or 0)) >= stuckMs
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

	local maxSearch = (ExpeditionConfig and tonumber(ExpeditionConfig.HOLD_PATH_MAX)) or PATH_MAX_SEARCH
	if maxSearch < 1 then
		maxSearch = PATH_MAX_SEARCH
	end
	local minDist, maxDist = 0, reach
	local excl = exclusiveWalkById[id]
	if force and excl and excl.x == dest.x and excl.y == dest.y and excl.z == dest.z then
		minDist = math.max(0, math.floor(tonumber(excl.minDist) or 0))
		maxDist = math.max(minDist, math.floor(tonumber(excl.maxDist) or 0))
	end
	local path = dirsForAutoWalkFromGetPathTo(creature:getPathTo(dest, minDist, maxDist, true, false, maxSearch))
	if type(path) ~= "table" or #path == 0 then
		lastPathFailById[id] = { key = key, at = now }
		-- Stance / follow retries (exact tile occupied, BLOCKPATH, etc.) are
		-- expected every tick. Only hold-to-hold relocate is worth a warning.
		if ignoreConditions then
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
	if creature:autoWalk(path, 0, skipConds) == true then
		lastQueuedWalkById[id] = { key = key, at = now, posKey = pkey }
		return true
	end

	-- Walk refused (e.g. walkTask raced in): clear and retry once with force.
	if creature.hasWalkTask and creature:hasWalkTask() then
		clearPendingWalkAction(creature)
		if creature:autoWalk(path, 0, true) == true then
			lastQueuedWalkById[id] = { key = key, at = now, posKey = pkey }
			return true
		end
	end

	if ignoreConditions then
		logWalkFail(creature, dest, "autoWalk refused", string.format("steps=%d relocate=true", #path))
	end
	clearQueuedWalk(creature)
	return false
end

local function clearFollowIfAny(player)
	if player and player.getFollowCreature and player:getFollowCreature() then
		player:setFollowCreature(nil)
	end
end

local function faceToward(player, toPos)
	if not player or not toPos then
		return
	end
	local fromPos = player:getPosition()
	if not fromPos or fromPos.z ~= toPos.z then
		return
	end
	local dx = toPos.x - fromPos.x
	local dy = toPos.y - fromPos.y
	if dx == 0 and dy == 0 then
		return
	end
	local dir
	if math.abs(dx) > math.abs(dy) then
		dir = dx > 0 and DIRECTION_EAST or DIRECTION_WEST
	else
		dir = dy > 0 and DIRECTION_SOUTH or DIRECTION_NORTH
	end
	if dir and player:getDirection() ~= dir then
		player:setDirection(dir)
	end
end

function CombatAutomationMovement.isInViewport(fromPos, toPos)
	if not fromPos or not toPos or fromPos.z ~= toPos.z then
		return false
	end
	return math.abs(fromPos.x - toPos.x) <= VIEWPORT_X and math.abs(fromPos.y - toPos.y) <= VIEWPORT_Y
end

local function stanceDistanceFor(config)
	local at = config and config.autoTarget or {}
	local role = at.stance or "melee"
	local rd = tonumber(at.rangedDistance) or 3
	if ExpeditionConfig and ExpeditionConfig.stanceDistanceFor then
		return ExpeditionConfig.stanceDistanceFor(role, role == "ranged" and rd or nil)
	end
	if CombatAutomationConfig and CombatAutomationConfig.stanceDistanceFor then
		return CombatAutomationConfig.stanceDistanceFor(role, role == "ranged" and rd or nil)
	end
	if role == "ranged" then
		return 3
	end
	return 1
end

--- Configured Chebyshev distance, optionally +1 while holding/following the party anchor.
local function stanceDistanceForFocus(config, vsAnchor)
	local d = stanceDistanceFor(config)
	if vsAnchor then
		d = d + 1
	end
	return math.max(1, d)
end

local function autoEnabled(config)
	return type(config) == "table"
		and type(config.autoTarget) == "table"
		and config.autoTarget.enabled == true
end

local function tileFreeForPlayer(player, pos)
	if not player or not pos then
		return false
	end
	local tile = Tile(pos)
	if not tile or not tile.getGround or not tile:getGround() then
		return false
	end
	if tile.hasProperty and CONST_PROP_BLOCKSOLID and tile:hasProperty(CONST_PROP_BLOCKSOLID) then
		return false
	end
	local top = tile.getTopCreature and tile:getTopCreature()
	if top and top.getId and top:getId() ~= player:getId() then
		return false
	end
	return true
end

--- Cardinal tiles at exact Chebyshev distance `d` (N/S/E/W), nearest first.
local function cardinalTilesAtDistance(focusPos, d)
	d = math.max(1, math.floor(tonumber(d) or 1))
	if not focusPos then
		return {}
	end
	return {
		Position(focusPos.x + d, focusPos.y, focusPos.z),
		Position(focusPos.x - d, focusPos.y, focusPos.z),
		Position(focusPos.x, focusPos.y + d, focusPos.z),
		Position(focusPos.x, focusPos.y - d, focusPos.z),
	}
end

-- Ranged stance settles anywhere within this many tiles of the stance distance.
local STANCE_BAND = 1

--- Hold Chebyshev distance `d` from focus.
--- `cardinal` (anchor formation, no combat focus): nearest free N/S/E/W tile. The
--- player keeps facing its last target instead of turning toward the anchor.
--- Combat focus: settle anywhere within STANCE_BAND inside `d` of the target, facing it.
local function holdStanceDistance(player, focus, d, cardinal)
	if not player or not focus then
		return
	end
	d = math.max(1, math.floor(tonumber(d) or 1))
	local ppos = player:getPosition()
	local fpos = focus.getPosition and focus:getPosition() or focus
	if not ppos or not fpos or not fpos.x then
		return
	end
	if ppos.z ~= fpos.z then
		return
	end

	local dist = chebyshev(ppos, fpos)
	if cardinal then
		local best, bestDist = nil, nil
		for _, dest in ipairs(cardinalTilesAtDistance(fpos, d)) do
			if tileFreeForPlayer(player, dest) then
				local destDist = chebyshev(ppos, dest)
				if not bestDist or destDist < bestDist then
					best, bestDist = dest, destDist
				end
			end
		end
		if best then
			if sameTile(ppos, best) then
				clearQueuedWalk(player)
				return
			end
			CombatAutomationMovement.queueWalkToward(player, best, false)
			return
		end
		if dist == d then
			clearQueuedWalk(player)
			return
		end
	elseif dist <= d and dist >= d - STANCE_BAND then
		clearQueuedWalk(player)
		faceToward(player, fpos)
		return
	end
	local path = dirsForAutoWalkFromGetPathTo(player:getPathTo(fpos, d, d, true, false, 16))
	if type(path) == "table" and #path > 0 then
		local id = player:getId()
		local key = "ring:" .. walkDestKey(fpos) .. ":" .. tostring(d)
		local prev = lastQueuedWalkById[id]
		local now = nowMs()
		local pkey = posKey(ppos)
		local stuckMs = (ExpeditionConfig and tonumber(ExpeditionConfig.STATE_REPATH_MS)) or STALL_REPATH_MS
		local stuck = prev and prev.key == key and prev.posKey and prev.posKey == pkey and (now - (prev.at or 0)) >= stuckMs
		if prev and prev.key == key and not stuck and (now - (prev.at or 0)) < WALK_DEDUPE_MS then
			return
		end
		if stuck and player.clearWalkTask then
			player:clearWalkTask()
		end
		if player:autoWalk(path, 0, stuck) == true then
			lastQueuedWalkById[id] = { key = key, at = now, posKey = pkey }
			return
		end
	end

	CombatAutomationMovement.queueWalkToward(player, fpos, false)
end

function CombatAutomationMovement.applyCreatureStance(player, target, config)
	if not player or not target then
		return
	end
	if not autoEnabled(config) then
		clearFollowIfAny(player)
		return
	end
	local d = stanceDistanceForFocus(config, false)
	-- Melee (d=1): engine follow tracks a moving focus well.
	-- Farther: any tile at the Chebyshev distance (not only cardinals).
	if d <= 1 then
		local follow = player.getFollowCreature and player:getFollowCreature()
		if not follow or follow:getId() ~= target:getId() then
			player:setFollowCreature(target)
		end
	else
		clearFollowIfAny(player)
		holdStanceDistance(player, target, d, false)
	end
end

function CombatAutomationMovement.setDirective(player, directive)
	local state = CombatAutomation.getState(player)
	if not state then
		return
	end
	local prev = state.directive
	if type(directive) ~= "table" or not directive.kind then
		if prev and prev.kind == "follow" then
			clearFollowIfAny(player)
		end
		state.directive = nil
		return
	end
	if prev and prev.kind == "follow" and directive.kind ~= "follow" then
		clearFollowIfAny(player)
	end
	state.directive = directive
end

function CombatAutomationMovement.clearDirective(player, kind)
	local state = CombatAutomation.getState(player)
	if not state or not state.directive then
		return
	end
	if kind == nil or state.directive.kind == kind then
		if state.directive.kind == "follow" then
			clearFollowIfAny(player)
		end
		state.directive = nil
	end
end

function CombatAutomationMovement.getDirective(player)
	local state = CombatAutomation.getState(player)
	return state and state.directive or nil
end

function CombatAutomationMovement.clearWalkDedupe(player)
	clearQueuedWalk(player)
	clearPendingWalkAction(player)
end

--- Force-walk to `dest` (or within optional [minDist,maxDist] Chebyshev) and keep
--- owning the path until arrival / TTL. Used by discovery POI FAB — not a general
--- client-walk unlock. `minDist`/`maxDist` let city pathfinding stop on any tile
--- inside the discovery radius instead of requiring one exact (often blocked) sqm.
function CombatAutomationMovement.beginExclusiveWalk(player, dest, ttlMs, minDist, maxDist)
	if not player or not dest then
		return false
	end
	local x = tonumber(dest.x)
	local y = tonumber(dest.y)
	local z = tonumber(dest.z)
	if not x or not y or not z then
		return false
	end
	minDist = math.max(0, math.floor(tonumber(minDist) or 0))
	maxDist = math.max(minDist, math.floor(tonumber(maxDist) or 0))
	local id = player:getId()
	exclusiveWalkById[id] = {
		x = x,
		y = y,
		z = z,
		minDist = minDist,
		maxDist = maxDist,
		untilMs = nowMs() + (tonumber(ttlMs) or EXCLUSIVE_WALK_TTL_MS),
	}
	clearFollowIfAny(player)
	local target = Position(x, y, z)
	local ppos = player:getPosition()
	if ppos and ppos.z == z then
		local cheb = math.max(math.abs(ppos.x - x), math.abs(ppos.y - y))
		if maxDist > 0 and cheb <= maxDist and cheb >= minDist then
			exclusiveWalkById[id] = nil
			clearQueuedWalk(player)
			return true
		end
		if maxDist == 0 and sameTile(ppos, target) then
			exclusiveWalkById[id] = nil
			clearQueuedWalk(player)
			return true
		end
	end
	local ok = CombatAutomationMovement.queueWalkToward(player, target, true) == true
	if not ok then
		exclusiveWalkById[id] = nil
	end
	return ok
end

function CombatAutomationMovement.clearExclusiveWalk(player)
	if player then
		exclusiveWalkById[player:getId()] = nil
	end
end

local function followComplete(player, directive)
	if not directive or directive.kind ~= "follow" then
		return true
	end
	local hold = directive.holdPos
	local targetId = tonumber(directive.targetId) or 0
	local anchor = targetId > 0 and Player(targetId) or nil
	if not anchor then
		return true
	end
	local apos = anchor:getPosition()
	local ppos = player:getPosition()
	if not apos or not ppos then
		return false
	end
	local atHold = not hold or sameTile(apos, hold)
	return atHold and CombatAutomationMovement.isInViewport(ppos, apos)
end

function CombatAutomationMovement.isFollowComplete(player, directive)
	return followComplete(player, directive)
end

--- Follow anchor at configured stance distance +1 (formation spacing).
local function driveFollow(player, anchor, config)
	if not player or not anchor then
		return
	end
	local d = stanceDistanceForFocus(config, true)
	if d <= 1 then
		local follow = player.getFollowCreature and player:getFollowCreature()
		if follow and follow:getId() == anchor:getId() then
			return
		end
		clearQueuedWalk(player)
		if player.setFollowCreature then
			player:setFollowCreature(anchor)
		end
		return
	end
	clearFollowIfAny(player)
	holdStanceDistance(player, anchor, d, true)
end

--- Promote finished follow into cardinal stance vs the parked anchor until combat focus.
local function promoteFollowToAnchorStance(player, directive)
	if not player or not directive then
		return
	end
	local targetId = tonumber(directive.targetId) or 0
	local hold = directive.holdPos
	clearFollowIfAny(player)
	if targetId <= 0 then
		CombatAutomationMovement.clearDirective(player, "follow")
		return
	end
	CombatAutomationMovement.setDirective(player, {
		kind = "anchorStance",
		targetId = targetId,
		holdPos = hold and Position(hold.x, hold.y, hold.z) or nil,
	})
end

--- Per-tick positioning: follow → anchorStance → hold → stance vs attack target.
function CombatAutomationMovement.tick(player, config)
	if not player then
		return
	end
	-- Let walk-then-act (Use / use-with) finish without stance/hold stealing the path.
	if player.hasWalkTask and player:hasWalkTask() then
		return
	end

	-- Discovery POI (and similar) exclusive walks outrank expedition hold/stance.
	local excl = exclusiveWalkById[player:getId()]
	if excl then
		local ppos = player:getPosition()
		local dest = Position(excl.x, excl.y, excl.z)
		local minDist = math.max(0, math.floor(tonumber(excl.minDist) or 0))
		local maxDist = math.max(minDist, math.floor(tonumber(excl.maxDist) or 0))
		local inRange = false
		if ppos and ppos.z == dest.z then
			local cheb = math.max(math.abs(ppos.x - dest.x), math.abs(ppos.y - dest.y))
			if maxDist > 0 then
				inRange = cheb <= maxDist and cheb >= minDist
			else
				inRange = sameTile(ppos, dest)
			end
		end
		if not ppos or nowMs() >= (excl.untilMs or 0) or ppos.z ~= dest.z or inRange then
			exclusiveWalkById[player:getId()] = nil
		else
			clearFollowIfAny(player)
			CombatAutomationMovement.queueWalkToward(player, dest, true)
			return
		end
	end

	config = config or {}
	local state = CombatAutomation.getState(player)
	local pendingStep = state and state.pendingAreaCast
	if pendingStep then
		clearFollowIfAny(player)
		-- Idle tick: walk already finished. Do not start another step.
		if not pendingStep.idle then
			local ppos = player:getPosition()
			local dest = Position(pendingStep.x, pendingStep.y, pendingStep.z)
			if not ppos or not sameTile(ppos, dest) then
				if nowMs() < (pendingStep.untilMs or 0) then
					CombatAutomationMovement.queueWalkToward(player, dest, true)
				end
			end
		end
		return
	end
	if state and state.skipStanceForAreaCast then
		clearFollowIfAny(player)
		return
	end

	local directive = state and state.directive or nil

	if directive and directive.kind == "follow" then
		if followComplete(player, directive) then
			promoteFollowToAnchorStance(player, directive)
			directive = state and state.directive or nil
		else
			local anchor = Player(tonumber(directive.targetId) or 0)
			if anchor then
				driveFollow(player, anchor, config)
			end
			return
		end
	end

	local autoOn = autoEnabled(config)
	local target = player:getTarget()
	local hasFocus = target
		and CombatAutomation.isValidAttackTarget
		and CombatAutomation.isValidAttackTarget(player, target)
		and CombatAutomationMovement.isInViewport(player:getPosition(), target:getPosition())
	if hasFocus and state then
		state.focusAt = nowMs()
	end
	-- Between kills: stay put rather than stepping back to formation for one tick.
	local betweenTargets = not hasFocus and state and nowMs() - (state.focusAt or 0) < FOCUS_GRACE_MS

	if directive and directive.kind == "anchorStance" then
		if hasFocus and autoOn then
			CombatAutomationMovement.applyCreatureStance(player, target, config)
			return
		end
		if betweenTargets and autoOn then
			return
		end
		local anchor = Player(tonumber(directive.targetId) or 0)
		if anchor and autoOn then
			clearFollowIfAny(player)
			holdStanceDistance(player, anchor, stanceDistanceForFocus(config, true), true)
		elseif not autoOn then
			clearFollowIfAny(player)
		end
		return
	end

	if directive and directive.kind == "hold" then
		local hold = directive.pos or directive.holdPos
		local relocatePriority = directive.priority == "relocate"
		if betweenTargets and autoOn and not relocatePriority then
			return
		end
		if hold and (relocatePriority or not hasFocus or not autoOn) then
			clearFollowIfAny(player)
			if autoOn or relocatePriority then
				if not sameTile(player:getPosition(), hold) then
					-- Do not force-repath every tick: autoWalk waits a stepDuration
					-- before the first tile, so a 250ms force restart never moves.
					-- Stuck detection inside queueWalkToward retries after ~400ms.
					CombatAutomationMovement.queueWalkToward(player, hold, false, relocatePriority, directive.reach)
				else
					clearQueuedWalk(player)
				end
			end
			return
		end
		-- Has combat focus while hold is soft: demote to stance.
		if hasFocus and autoOn and not relocatePriority then
			CombatAutomationMovement.applyCreatureStance(player, target, config)
			return
		end
	end

	if hasFocus and autoOn then
		CombatAutomationMovement.applyCreatureStance(player, target, config)
	else
		-- Never keep trailing an old follow target once directives are gone.
		clearFollowIfAny(player)
	end
end

function CombatAutomationMovement.onAutoResumed(player)
	if not player then
		return
	end
	clearQueuedWalk(player)
	clearPendingWalkAction(player)
	clearFollowIfAny(player)
	local state = CombatAutomation.getState(player)
	if state then
		state.pendingAreaCast = nil
		state.skipStanceForAreaCast = nil
		state.areaCastSlotId = nil
		state.areaFace = nil
		state.suppressAreaStep = nil
	end
end
