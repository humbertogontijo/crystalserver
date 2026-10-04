-- Per-player automation movement: hold / follow directives + creature stance.
-- Pathfinding: Creature:getPathTo + autoWalk. On stall / blocked walk, drop the
-- pending path and recalculate — same idea as client autowalk repathing.
-- Pending walk-then-act (Use / use-with under idle combat) is preserved so echo
-- portal / tame FABs can finish walking adjacent.

CombatAutomationMovement = CombatAutomationMovement or {}

local lastQueuedWalkById = {}
local lastPathFailLogById = {}
--- Last getPathTo failure per creature: { key = dest key, at = ms, count = in a row }.
local lastPathFailById = {}
-- Temporary exclusive destinations (discovery POI FAB). Blocks stance/hold from
-- stealing the path under idle combat without unlocking general client autoWalk.
local exclusiveWalkById = {}

local PATH_MAX_SEARCH = 128
local WALK_DEDUPE_MS = 2500
local STALL_REPATH_MS = 400
local EXCLUSIVE_WALK_TTL_MS = 20000
local PATH_FAIL_FRESH_MS = 1500
--- Failures in a row (one per tick) before a destination counts as blocked: a
--- path closed for a moment by a passing creature is not.
local PATH_FAIL_PERSIST = 3
local FOCUS_GRACE_MS = 1000

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

local function walkDestKey(pos)
	if not pos then
		return nil
	end
	return string.format("%d,%d,%d", pos.x, pos.y, pos.z)
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
	local pkey = walkDestKey(ppos)
	local stuckMs = (ExpeditionConfig and tonumber(ExpeditionConfig.FORMATION_REPATH_MS)) or STALL_REPATH_MS
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
		local fail = lastPathFailById[id]
		local count = 1
		if fail and fail.key == key and (now - fail.at) <= PATH_FAIL_FRESH_MS then
			count = fail.count + 1
		end
		lastPathFailById[id] = { key = key, at = now, count = count }
		-- Stance / follow retries (exact tile occupied, BLOCKPATH, etc.) are
		-- expected every tick. Only a route walk that stays blocked is worth a warning.
		if ignoreConditions and count == PATH_FAIL_PERSIST then
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
	local stuck = prev and prev.key == key and prev.posKey == pkey and (now - (prev.at or 0)) >= STALL_REPATH_MS
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

-- Ranged stance settles anywhere within this many tiles of the stance distance.
local STANCE_BAND = 1

local function sightClear(player, from, to)
	if not from.isSightClear then
		return true
	end
	return from:isSightClear(to, true, player.getInstanceId and player:getInstanceId() or 0)
end

-- Fight positioning knobs.
local REPOSITION_MIN_FREE = 3
local ADJUST_THROTTLE_MS = 500
local SEARCH_RADIUS = 3
local RANGED_SAFE_DIST = 2

--- Visible monsters that are fighting someone (their target is set); `mineOnly`:
--- only those targeting `player`.
local function threatPositions(player, mineOnly)
	local out = {}
	local monsters = CombatAutomation.visibleMonsters and CombatAutomation.visibleMonsters(player) or {}
	local myId = player:getId()
	for _, monster in ipairs(monsters) do
		local target = monster:getTarget()
		if target and (not mineOnly or target:getId() == myId) then
			out[#out + 1] = monster:getPosition()
		end
	end
	return out
end

local function nearestThreat(pos, threats)
	local best = math.huge
	for _, t in ipairs(threats) do
		if t.z == pos.z then
			local d = chebyshev(pos, t)
			if d < best then
				best = d
			end
		end
	end
	return best
end

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

--- Monster types that cast beams / waves (directional areas), cached per name.
local directionalByName = {}
local function castsDirectional(monster)
	local mType = monster.getType and monster:getType()
	if not mType or not mType.getAttackList then
		return false
	end
	local name = mType:name()
	local cached = directionalByName[name]
	if cached == nil then
		cached = false
		for _, attack in ipairs(mType:getAttackList() or {}) do
			if attack.needDirection then
				cached = true
				break
			end
		end
		directionalByName[name] = cached
	end
	return cached
end

local CARDINAL_OFFSETS = geo.CARDINAL_OFFSETS

--- Ring of 8 standable neighbours plus all four ranged lanes.
local ANCHOR_TILE_IDEAL = 8 + 2 * 4
--- Good enough to stay: full ring and this many lanes.
local ANCHOR_TILE_GOOD_LANES = 2
--- Halt tile search depth, in walking steps from the anchor.
local ANCHOR_SPOT_MAX_STEPS = 8

local function standableAt(z)
	return function(x, y)
		return geo.tileStandable(Position(x, y, z)) ~= nil
	end
end

--- Memoized `standable(x, y)` for one floor (a viewport search re-reads each tile ~20x).
local function memoStandable(z)
	local raw, memo = standableAt(z), {}
	return function(x, y)
		local key = x * 65536 + y
		local v = memo[key]
		if v == nil then
			v = raw(x, y)
			memo[key] = v
		end
		return v
	end
end

--- Farthest lane slot a ranged companion takes from the anchor (its ranged distance
--- + 1, see `memberTileScore`), or nil for melee.
function CombatAutomationMovement.rangedSlotDistance(player)
	local config = player and CombatAutomationStore and CombatAutomationStore.getConfig(player)
	local at = config and config.autoTarget
	if not at or at.stance ~= "ranged" then
		return nil
	end
	return CombatAutomationConfig.stanceDistanceOf(config) + 1
end

local function defaultLaneDistance()
	return CombatAutomationConfig.RANGED_DISTANCE_DEFAULT + 1
end

--- How far past the lane slots mages may walk around the anchor's 3x3 to change side.
local LANE_LINK_MARGIN = 3

--- Largest group of lane slots (`tips`) still walkable to each other with the anchor's
--- 3x3 filled (anchor + monster ring), walking within laneDist + LANE_LINK_MARGIN of
--- the anchor. A 3x3 that seals a corridor splits the slots, trapping mages on a side.
local function linkedLaneCount(pos, standable, laneDist, tips)
	if #tips <= 1 then
		return #tips
	end
	local radius = laneDist + LANE_LINK_MARGIN
	local tipAt = {}
	for i, tip in ipairs(tips) do
		tipAt[tip[1] * 65536 + tip[2]] = i
	end
	local grouped, best = {}, 0
	for i, tip in ipairs(tips) do
		if not grouped[i] then
			grouped[i] = true
			local members = 1
			local seen = { [tip[1] * 65536 + tip[2]] = true }
			local queue, head = { tip }, 1
			while queue[head] do
				local cur = queue[head]
				head = head + 1
				for _, off in ipairs(geo.NEIGHBOUR_OFFSETS) do
					local x, y = cur[1] + off[1], cur[2] + off[2]
					local key = x * 65536 + y
					local dx, dy = math.abs(x - pos.x), math.abs(y - pos.y)
					if not seen[key] and math.max(dx, dy) <= radius and (dx > 1 or dy > 1) and standable(x, y) then
						seen[key] = true
						queue[#queue + 1] = { x, y }
						local j = tipAt[key]
						if j and not grouped[j] then
							grouped[j] = true
							members = members + 1
						end
					end
				end
			end
			best = math.max(best, members)
		end
	end
	return best
end

--- Expedition anchor fight tile, from terrain only: standable neighbours (room for a
--- full ring of monsters, up to 8) plus cardinal lanes standable all the way out to
--- `laneDist` (the lane slots memberTileScore rewards, in clear sight of the anchor), counting only
--- the largest group of lanes that stay linked around the filled 3x3 (up to 4), each
--- worth 2. Returns score, ring, lanes. When the unlinked score cannot beat `beat`,
--- returns that upper bound without the (costlier) link check.
local function anchorTileScore(pos, standable, laneDist, beat)
	standable = standable or standableAt(pos.z)
	laneDist = laneDist or defaultLaneDistance()
	local ring = 0
	for _, off in ipairs(geo.NEIGHBOUR_OFFSETS) do
		if standable(pos.x + off[1], pos.y + off[2]) then
			ring = ring + 1
		end
	end
	local tips = {}
	for _, d in ipairs(CARDINAL_OFFSETS) do
		local open = true
		for step = 1, laneDist do
			if not standable(pos.x + step * d[1], pos.y + step * d[2]) then
				open = false
				break
			end
		end
		if open then
			tips[#tips + 1] = { pos.x + laneDist * d[1], pos.y + laneDist * d[2] }
		end
	end
	if beat and ring + 2 * #tips <= beat then
		return ring + 2 * #tips, ring, #tips
	end
	local lanes = linkedLaneCount(pos, standable, laneDist, tips)
	return ring + 2 * lanes, ring, lanes
end

local function anchorTileGood(pos, standable, laneDist)
	local _, ring, lanes = anchorTileScore(pos, standable, laneDist)
	return ring >= 8 and lanes >= ANCHOR_TILE_GOOD_LANES
end

--- Expedition halt tile. Stays on `prefer` (the route hold) or where the anchor
--- stands when that tile is already good (full ring, ANCHOR_TILE_GOOD_LANES lanes);
--- otherwise walks outward (up to ANCHOR_SPOT_MAX_STEPS steps, within the viewport)
--- and takes the best `anchorTileScore`, nearest by walk on ties. The walk only
--- crosses free tiles (monsters and members block), so every pick is reachable now.
--- `exclude`: set of `x * 65536 + y` keys never picked (tiles that failed to path).
--- `laneDist`: the team's ranged slot distance (`rangedSlotDistance`); kept on the
--- anchor for its tile adjustments. Returns pos, score, ring, lanes.
function CombatAutomationMovement.bestAnchorSpot(anchor, prefer, laneDist, exclude)
	local apos = anchor and anchor:getPosition()
	if not apos then
		return nil
	end
	laneDist = laneDist or defaultLaneDistance()
	local anchorState = CombatAutomation.getState(anchor)
	if anchorState then
		anchorState.anchorLaneDist = laneDist
	end
	local standable = memoStandable(apos.z)
	local function result(pos)
		return pos, anchorTileScore(pos, standable, laneDist)
	end
	exclude = exclude or {}
	if prefer and (prefer.z ~= apos.z or exclude[prefer.x * 65536 + prefer.y]) then
		prefer = nil
	end
	if prefer and anchorTileGood(prefer, standable, laneDist) then
		return result(prefer)
	end
	if anchorTileGood(apos, standable, laneDist) then
		return result(apos)
	end

	local best, bestScore = apos, (anchorTileScore(apos, standable, laneDist))
	if prefer and tileFree(prefer, anchor) then
		local score = anchorTileScore(prefer, standable, laneDist)
		if score >= bestScore then
			best, bestScore = prefer, score
		end
	end
	local seen = { [apos.x * 65536 + apos.y] = true }
	local frontier = { apos }
	for _ = 1, ANCHOR_SPOT_MAX_STEPS do
		local nextFrontier = {}
		for _, from in ipairs(frontier) do
			for _, off in ipairs(geo.NEIGHBOUR_OFFSETS) do
				local x, y = from.x + off[1], from.y + off[2]
				local key = x * 65536 + y
				if not seen[key] then
					seen[key] = true
					local pos = Position(x, y, apos.z)
					if standable(x, y) and geo.isInViewport(apos, pos) and tileFree(pos, anchor) then
						nextFrontier[#nextFrontier + 1] = pos
						if not exclude[key] and not fartherFromLeash(anchor, apos, pos) then
							local score = anchorTileScore(pos, standable, laneDist, bestScore)
							if score > bestScore then
								best, bestScore = pos, score
								if score >= ANCHOR_TILE_IDEAL then
									return result(best)
								end
							end
						end
					end
				end
			end
		end
		frontier = nextFrontier
	end
	return result(best)
end

--- Anchor next to its target: when its tile is not good, one step
--- to a free tile still next to the target that scores strictly better.
local function adjustAnchorTile(player, target, state)
	if throttled(state, "anchorAdjustAt", ADJUST_THROTTLE_MS) then
		return false
	end
	local ppos = player:getPosition()
	local laneDist = state and state.anchorLaneDist
	local standable = memoStandable(ppos.z)
	if anchorTileGood(ppos, standable, laneDist) then
		return false
	end
	local here = anchorTileScore(ppos, standable, laneDist)
	local tpos = target:getPosition()
	local best, bestScore = nil, here
	for _, off in ipairs(geo.NEIGHBOUR_OFFSETS) do
		local pos = Position(ppos.x + off[1], ppos.y + off[2], ppos.z)
		if chebyshev(pos, tpos) == 1 and tileFree(pos, player) and not fartherFromLeash(player, ppos, pos) then
			local score = anchorTileScore(pos, standable, laneDist, bestScore)
			if score > bestScore then
				best, bestScore = pos, score
			end
		end
	end
	return best ~= nil and stepTo(player, best)
end

local function isExpeditionAnchor(state)
	local directive = state and state.directive
	return directive ~= nil and directive.kind == "hold"
end

--- Engine follow tracks a moving target well until adjacent.
local function followTarget(player, target)
	local follow = player.getFollowCreature and player:getFollowCreature()
	if not follow or follow:getId() ~= target:getId() then
		player:setFollowCreature(target)
	end
end

local function anchorMeleeStance(player, target, state)
	if chebyshev(player:getPosition(), target:getPosition()) <= 1 then
		adjustAnchorTile(player, target, state)
		return
	end
	followTarget(player, target)
end

-- ---------------------------------------------------------------------------
-- Member positioning (every non-anchor member, any stance): one tile score set by
-- the stance distance d. With an anchor the member takes its slot d + 1 from it,
-- best on a cardinal lane (ranged: two free tiles between it and the monster box
-- around the anchor, so a wave covers the box; melee: right outside the box), and
-- keeps out of the anchor's 3x3 where monsters stand. Ranged also keeps away from monsters
-- targeting it; melee fights next to its target and never steps away from monsters
-- (low HP is retreatIfCritical's job).
-- ---------------------------------------------------------------------------

local RANGED_TARGET_RANGE = 7
--- A target farther than d + this from the anchor is not chased: the member keeps
--- its slot and lets it come.
local CHASE_MARGIN = 3
--- Tiles next to the anchor (its monster ring) lose this much.
local ANCHOR_RING_PENALTY = 50
local MELEE_ROOM_PER_TILE = 8
local MELEE_FACING_BONUS = 15
--- An area slot that wanted a better tile keeps scoring this long, so the member
--- stays on the tile it walked to.
local AREA_SLOT_MEMORY_MS = 4000
local AREA_BONUS_CAP = 60
--- Leave the current tile only for one scoring at least this much more.
local TILE_MOVE_MARGIN = 5

local function slotById(config, id)
	for _, slot in ipairs(config and config.slots or {}) do
		if slot.id == id then
			return slot
		end
	end
	return nil
end

local function rememberedAreaSlot(config, state)
	if not state or not CombatAutomation.areaSlotHitsAt then
		return nil
	end
	if nowMs() - (state.areaBlockedAt or 0) > AREA_SLOT_MEMORY_MS then
		return nil
	end
	return slotById(config, state.areaBlockedSlotId)
end

--- Member tile score (nil: unusable). Needs a free tile inside the leash in clear
--- sight of the anchor and target; melee next to the target, ranged
--- 2..RANGED_TARGET_RANGE from it. Scores the anchor slot and ring (above), then per
--- stance: ranged safety from monsters targeting it (dominant) or, alone, the stance
--- band around the target; melee facing (diagonal to beam casters, orthogonal for
--- its own wave spells) and a penalty when boxed in. Plus area-spell hits, minus
--- walking, plus a little for the destination already chosen (a new one every tick
--- restarts autoWalk before its first step). Returns nil once it cannot beat `beat`.
local function memberTileScore(ctx, pos, beat)
	local player = ctx.player
	if not tileFree(pos, player) or fartherFromLeash(player, ctx.ppos, pos) then
		return nil
	end
	local tpos, apos = ctx.tpos, ctx.apos
	local score = 0
	if tpos then
		local ring = chebyshev(pos, tpos)
		if ctx.melee then
			if ring ~= 1 then
				return nil
			end
			local diagonal = pos.x ~= tpos.x and pos.y ~= tpos.y
			if (ctx.wantOrthogonal and not diagonal) or (not ctx.wantOrthogonal and ctx.dodgeBeams and diagonal) then
				score = score + MELEE_FACING_BONUS
			end
		else
			if ring < 2 or ring > RANGED_TARGET_RANGE then
				return nil
			end
			if not apos and math.abs(ring - ctx.d) <= STANCE_BAND then
				score = score + 20 + (ring == ctx.d and 2 or 0)
			end
		end
	end
	if apos then
		local d = chebyshev(pos, apos)
		local off = math.abs(d - ctx.slotDist)
		if off == 0 then
			score = score + (geo.onAnchorLane(pos, apos) and 40 or 20)
		elseif off == 1 then
			score = score + 8
		end
		if d <= 1 then
			score = score - ANCHOR_RING_PENALTY
		end
	end
	if not ctx.melee then
		local threat = nearestThreat(pos, ctx.threats)
		score = score + (threat >= ctx.safeDist and 100 or 0) + math.min(threat, 4) * 5
	end
	score = score - chebyshev(ctx.ppos, pos) * 2
	if ctx.prevDest and sameTile(pos, ctx.prevDest) then
		score = score + 3
	end
	if beat and score + (ctx.areaSlot and AREA_BONUS_CAP or 0) <= beat then
		return nil
	end
	if (apos and not sightClear(player, pos, apos)) or (tpos and not sightClear(player, pos, tpos)) then
		return nil
	end
	if ctx.melee then
		local boxed = ctx.minFree + 1 - geo.freeNeighbourCount(pos, player)
		if boxed > 0 then
			score = score - boxed * MELEE_ROOM_PER_TILE
		end
	end
	if ctx.areaSlot then
		local hits, passes = CombatAutomation.areaSlotHitsAt(player, ctx.areaSlot, pos)
		if passes then
			score = score + math.min(hits * 10, AREA_BONUS_CAP)
		end
	end
	if beat and score <= beat then
		return nil
	end
	return score
end

--- Melee with a target: the tiles next to it. Otherwise tiles around the member,
--- plus the anchor's slot square.
local function memberCandidates(ctx)
	local out, seen = {}, {}
	local function addSquare(center, r)
		for dx = -r, r do
			for dy = -r, r do
				local x, y = center.x + dx, center.y + dy
				local key = x * 65536 + y
				if not seen[key] then
					seen[key] = true
					out[#out + 1] = Position(x, y, center.z)
				end
			end
		end
	end
	if ctx.melee and ctx.tpos then
		addSquare(ctx.tpos, 1)
		return out
	end
	addSquare(ctx.ppos, SEARCH_RADIUS)
	if ctx.apos then
		addSquare(ctx.apos, ctx.slotDist)
	end
	return out
end

--- Best candidate; nil (stay) unless it beats the current tile by TILE_MOVE_MARGIN.
local function pickTile(ctx)
	local here = memberTileScore(ctx, ctx.ppos)
	local best, bestScore = nil, here and (here + TILE_MOVE_MARGIN) or nil
	for _, pos in ipairs(memberCandidates(ctx)) do
		if not sameTile(pos, ctx.ppos) then
			local score = memberTileScore(ctx, pos, bestScore)
			if score then
				best, bestScore = pos, score
			end
		end
	end
	return best
end

--- Non-anchor member (fighting, holding its slot, trailing the anchor, aiming an
--- area spell): walk to the best-scoring tile when it beats staying, else hold facing
--- the target. Melee reaches its target with engine follow first. `anchor`
--- (expedition formation) and `target` are optional. Re-evaluates every
--- ADJUST_THROTTLE_MS, or at once when a monster targeting a ranged member closes in.
local function driveMember(player, anchor, target, config, state)
	local ppos = player:getPosition()
	if not ppos then
		return
	end
	local apos = anchor and anchor:getPosition()
	if apos and apos.z ~= ppos.z then
		apos = nil
	end
	local d = CombatAutomationConfig.stanceDistanceOf(config)
	local melee = d <= 1
	local tpos = target and target:getPosition()
	if tpos and (tpos.z ~= ppos.z
		or (apos and chebyshev(tpos, apos) > d + CHASE_MARGIN
			and not (melee and chebyshev(ppos, tpos) <= 1)))
	then
		tpos = nil
	end
	if melee and tpos and chebyshev(ppos, tpos) > 1 then
		followTarget(player, target)
		return
	end
	if not (melee and tpos) then
		clearFollowIfAny(player)
	end
	if not tpos and not apos then
		return
	end
	local threats = melee and {} or threatPositions(player, true)
	local safeDist = RANGED_SAFE_DIST
	local unsafe = not melee and nearestThreat(ppos, threats) < safeDist
	if not unsafe and throttled(state, "memberEvalAt", ADJUST_THROTTLE_MS) then
		return
	end
	local ctx = {
		player = player,
		ppos = ppos,
		tpos = tpos,
		apos = apos,
		melee = melee,
		d = d,
		slotDist = d + 1,
		threats = threats,
		safeDist = safeDist,
		minFree = REPOSITION_MIN_FREE,
		wantOrthogonal = melee and tpos ~= nil and CombatAutomation.hasDirectionalAttackSlot ~= nil
			and CombatAutomation.hasDirectionalAttackSlot(config),
		dodgeBeams = melee and tpos ~= nil and castsDirectional(target),
		prevDest = state and state.memberDest,
		areaSlot = rememberedAreaSlot(config, state),
	}
	local best = pickTile(ctx)
	if state then
		state.memberDest = best
	end
	if best then
		clearFollowIfAny(player)
		CombatAutomationMovement.queueWalkToward(player, best, false)
		return
	end
	clearQueuedWalk(player)
	local facePos = target and target:getPosition()
	if facePos and facePos.z == ppos.z then
		faceToward(player, facePos)
	end
end

--- Low HP (ExpeditionConfig.isPositionCritical): step to the adjacent tile farthest
--- from fighting monsters (ties toward the leash anchor) while heals catch up.
--- True while a retreat step owns movement.
local function retreatIfCritical(player, state)
	if not state then
		return false
	end
	if not (ExpeditionConfig and ExpeditionConfig.isPositionCritical and ExpeditionConfig.isPositionCritical(player)) then
		state.retreating = nil
		return false
	end
	if throttled(state, "retreatAt", ADJUST_THROTTLE_MS) then
		return state ~= nil and state.retreating == true
	end
	local ppos = player:getPosition()
	local threats = threatPositions(player)
	local here = nearestThreat(ppos, threats)
	if here > 2 then
		state.retreating = nil
		return false
	end
	local anchor = player.getPathLeashAnchor and player:getPathLeashAnchor() or nil
	local best, bestThreat, bestAnchor = nil, here, nil
	for _, off in ipairs(geo.NEIGHBOUR_OFFSETS) do
		local pos = Position(ppos.x + off[1], ppos.y + off[2], ppos.z)
		if tileFree(pos, player) then
			local threat = nearestThreat(pos, threats)
			local toAnchor = (anchor and anchor.z == pos.z) and chebyshev(pos, anchor) or 0
			if threat > bestThreat or (best and threat == bestThreat and toAnchor < bestAnchor) then
				best, bestThreat, bestAnchor = pos, threat, toAnchor
			end
		end
	end
	if best then
		state.retreating = true
		stepTo(player, best)
		return true
	end
	state.retreating = nil
	return false
end

--- Fight positioning against `target`; `anchor` (optional) is the expedition anchor
--- the member positions around.
local function applyCreatureStance(player, target, config, anchor)
	if not player or not target then
		return
	end
	if not autoEnabled(config) then
		clearFollowIfAny(player)
		return
	end
	local state = CombatAutomation.getState(player)
	if retreatIfCritical(player, state) then
		return
	end
	if CombatAutomationConfig.stanceDistanceOf(config) <= 1 and isExpeditionAnchor(state) then
		anchorMeleeStance(player, target, state)
	else
		driveMember(player, anchor, target, config, state)
	end
end

--- The expedition anchor this member forms on (follow / anchorStance directive).
function CombatAutomationMovement.directiveAnchor(state)
	local directive = state and state.directive
	if not directive or (directive.kind ~= "anchorStance" and directive.kind ~= "follow") then
		return nil
	end
	return Player(tonumber(directive.targetId) or 0)
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

function CombatAutomationMovement.clearWalkDedupe(player)
	clearQueuedWalk(player)
	clearPendingWalkAction(player)
end

--- On the exclusive walk's destination tile, or inside its [minDist, maxDist] ring.
local function exclusiveArrived(ppos, excl)
	if not ppos or ppos.z ~= excl.z then
		return false
	end
	if excl.maxDist > 0 then
		local d = chebyshev(ppos, excl)
		return d >= excl.minDist and d <= excl.maxDist
	end
	return ppos.x == excl.x and ppos.y == excl.y
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
	if exclusiveArrived(player:getPosition(), exclusiveWalkById[id]) then
		exclusiveWalkById[id] = nil
		clearQueuedWalk(player)
		return true
	end
	local ok = CombatAutomationMovement.queueWalkToward(player, target, true) == true
	if not ok then
		exclusiveWalkById[id] = nil
	end
	return ok
end

--- Companion beyond the anchor's screen (or CATCH_UP_WALK_SQM) walks back toward it,
--- until within half that distance (hysteresis so fighting near the edge does not flap).
local function driveCatchUp(player, anchor, state)
	if not player or not anchor or not state then
		return false
	end
	local ppos = player:getPosition()
	local apos = anchor:getPosition()
	if not ppos or not apos or ppos.z ~= apos.z then
		state.catchingUp = nil
		return false
	end
	local walkSqm = (ExpeditionConfig and tonumber(ExpeditionConfig.CATCH_UP_WALK_SQM)) or 10
	local dist = chebyshev(ppos, apos)
	if state.catchingUp then
		if dist <= math.floor(walkSqm / 2) then
			state.catchingUp = nil
			clearQueuedWalk(player)
			return false
		end
	elseif dist > walkSqm or not geo.isInViewport(apos, ppos) then
		state.catchingUp = true
	else
		return false
	end
	clearFollowIfAny(player)
	local maxSearch = (ExpeditionConfig and tonumber(ExpeditionConfig.CATCH_UP_PATH_MAX)) or PATH_MAX_SEARCH
	walkTowardCreature(player, anchor, 2, maxSearch)
	return true
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
		if not ppos or nowMs() >= (excl.untilMs or 0) or ppos.z ~= dest.z or exclusiveArrived(ppos, excl) then
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
	local anchor = CombatAutomationMovement.directiveAnchor(state)

	if anchor then
		if driveCatchUp(player, anchor, state) then
			return
		end
	elseif state then
		state.catchingUp = nil
	end

	if directive and directive.kind == "follow" then
		if anchor then
			driveMember(player, anchor, nil, config, state)
		end
		return
	end

	local autoOn = autoEnabled(config)
	local target = player:getTarget()
	local hasFocus = target
		and CombatAutomation.isValidAttackTarget
		and CombatAutomation.isValidAttackTarget(player, target)
		and geo.isInViewport(player:getPosition(), target:getPosition())
	if hasFocus and state then
		state.focusAt = nowMs()
	end
	-- Between kills: stay put rather than stepping back to formation for one tick.
	local betweenTargets = not hasFocus and state and nowMs() - (state.focusAt or 0) < FOCUS_GRACE_MS

	if directive and directive.kind == "anchorStance" then
		if hasFocus and autoOn then
			applyCreatureStance(player, target, config, anchor)
			return
		end
		if betweenTargets and autoOn then
			return
		end
		if anchor and autoOn then
			driveMember(player, anchor, nil, config, state)
		elseif not autoOn then
			clearFollowIfAny(player)
		end
		return
	end

	if directive and directive.kind == "hold" then
		local hold = directive.pos
		local relocatePriority = directive.priority == "relocate"
		if hold and directive.luring then
			-- Luring (cave walk / pacing): keep to the route and attack only what is in
			-- range; never chase, so the pack follows the anchor instead.
			clearFollowIfAny(player)
			if relocatePriority then
				CombatAutomationMovement.queueWalkToward(player, hold, false, true, directive.reach)
			else
				clearQueuedWalk(player)
				if hasFocus then
					faceToward(player, target:getPosition())
				elseif type(directive.front) == "table" then
					local ppos = player:getPosition()
					faceToward(player, Position(ppos.x + directive.front[1], ppos.y + directive.front[2], ppos.z))
				end
			end
			return
		end
		if betweenTargets and autoOn and not relocatePriority then
			return
		end
		if hold and (relocatePriority or not hasFocus or not autoOn) then
			clearFollowIfAny(player)
			if autoOn or relocatePriority then
				if not sameTile(player:getPosition(), hold) then
					-- Do not force-repath every tick; stuck detection inside
					-- queueWalkToward retries after ~400ms.
					CombatAutomationMovement.queueWalkToward(player, hold, false, relocatePriority, directive.reach)
				else
					clearQueuedWalk(player)
					-- Tank waits facing where the pack comes from.
					local front = directive.front
					if not hasFocus and type(front) == "table" then
						faceToward(player, Position(hold.x + front[1], hold.y + front[2], hold.z))
					end
				end
			end
			return
		end
		-- Has combat focus while hold is soft: demote to stance.
		if hasFocus and autoOn and not relocatePriority then
			applyCreatureStance(player, target, config)
			return
		end
	end

	if hasFocus and autoOn then
		applyCreatureStance(player, target, config)
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
	end
end
