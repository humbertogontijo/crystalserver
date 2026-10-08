-- Automation movement, member formation: the tile score every non-anchor member
-- fights from, plus retreat and creature stance.

local geo = CombatGeo
local nowMs, sameTile, chebyshev, faceToward, tileFree, fartherFromLeash = geo.nowMs, geo.sameTile, geo.chebyshev, geo.faceToward, geo.tileFree, geo.fartherFromLeash
local settings = CombatAutomationConfig
local inBossFront, BOSS_FRONT_PENALTY, linesCovering = MOVE_PRIV.inBossFront, MOVE_PRIV.BOSS_FRONT_PENALTY, MOVE_PRIV.linesCovering
local followTarget, clearFollowIfAny, bossFronts, throttled = MOVE_PRIV.followTarget, MOVE_PRIV.clearFollowIfAny, MOVE_PRIV.bossFronts, MOVE_PRIV.throttled
local ADJUST_THROTTLE_MS, slotDistanceOf, lineDanger, directionalShape = MOVE_PRIV.ADJUST_THROTTLE_MS, MOVE_PRIV.slotDistanceOf, MOVE_PRIV.lineDanger, MOVE_PRIV.directionalShape
local stepTo, autoEnabled, isExpeditionAnchor = MOVE_PRIV.stepTo, MOVE_PRIV.autoEnabled, MOVE_PRIV.isExpeditionAnchor
local anchorMeleeStance = MOVE_PRIV.anchorMeleeStance

-- ---------------------------------------------------------------------------
-- Member positioning (every non-anchor member, any stance): one tile score set by
-- the stance distance d. With an anchor the member takes its slot d + 1 from it,
-- best on a cardinal lane (ranged: two free tiles between it and the monster box
-- around the anchor, so a wave covers the box; melee: right outside the box, on any
-- side while it stands next to the anchor), and
-- keeps out of the anchor's 3x3 where monsters stand and out of wave / beam lines
-- (`lineDanger`). Ranged also keeps away from monsters
-- targeting it; melee fights next to its target and never steps away from monsters
-- (low HP is retreatIfCritical's job). Formation is only for fighting: without a
-- target the member trails (TRAIL_RADIUS, never ahead of the anchor) instead of
-- taking its slot.
-- ---------------------------------------------------------------------------

-- Ranged stance settles anywhere within this many tiles of the stance distance.
local STANCE_BAND = 1

local REPOSITION_MIN_FREE = 3
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
--- Score lost per walking step: a fight slot close by beats a better lane across the
--- box. A ranged member a monster closes in on walks cheaply, to get clear of it.
local SLOT_WALK_COST = 6
local UNSAFE_WALK_COST = 2
--- Without a target a member trails within this many tiles of the anchor, never
--- ahead of it along the travel front.
local TRAIL_RADIUS = 3
--- Per wave / beam line covering a tile (up to LINE_MAX_CASTERS lines).
local LINE_PENALTY = 40
local LINE_MAX_CASTERS = 3

local function slotById(config, id)
	for _, slot in ipairs(config and config.slots or {}) do
		if slot.id == id then
			return slot
		end
	end
	return nil
end

local function rememberedAreaSlot(config, state)
	if not state then
		return nil
	end
	if nowMs() - (state.areaBlockedAt or 0) > AREA_SLOT_MEMORY_MS then
		return nil
	end
	return slotById(config, state.areaBlockedSlotId)
end

--- Member tile score (nil: unusable). Needs a free tile inside the leash in clear
--- sight of the anchor and target; melee next to the target, ranged
--- 2..RANGED_TARGET_RANGE from it; trailing, within TRAIL_RADIUS of the anchor and
--- not ahead of it. Scores the anchor slot (not when trailing) and ring, then per
--- stance: ranged safety from monsters targeting it (dominant) or, alone, the stance
--- band around the target; melee facing (diagonal to beam casters, orthogonal for
--- its own wave spells) and a penalty when boxed in. Plus area-spell hits, minus
--- walking, plus a little for the destination already chosen (a new one every tick
--- restarts autoWalk before its first step), less BOSS_FRONT_PENALTY in a boss front
--- and LINE_PENALTY per wave / beam line over it (members of an anchor only).
--- Returns nil once it cannot beat `beat`.
local function memberTileScore(ctx, pos, beat)
	local player = ctx.player
	local flags = ctx.mask[geo.tileKey(pos.x, pos.y)]
	if not geo.maskFree(flags) or fartherFromLeash(player, ctx.ppos, pos) then
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
		if ctx.trail then
			local front = ctx.front
			if d > TRAIL_RADIUS or (front and (pos.x - apos.x) * front[1] + (pos.y - apos.y) * front[2] > 0) then
				return nil
			end
		else
			local off = math.abs(d - ctx.slotDist)
			if off == 0 then
				score = score + ((ctx.anchorLanes and geo.onAnchorLane(pos, apos)) and 40 or 20)
			elseif off == 1 then
				score = score + 8
			end
		end
		if d <= 1 then
			score = score - ANCHOR_RING_PENALTY
		end
	end
	if not ctx.melee then
		local threat = nearestThreat(pos, ctx.threats)
		score = score + (threat >= ctx.safeDist and 100 or 0) + math.min(threat, 4) * 5
	end
	score = score - chebyshev(ctx.ppos, pos) * ctx.walkCost
	if ctx.prevDest and sameTile(pos, ctx.prevDest) then
		score = score + 3
	end
	if ctx.bosses[1] and inBossFront(player, pos, ctx.bosses) then
		score = score - BOSS_FRONT_PENALTY
	end
	if ctx.lines then
		score = score - LINE_PENALTY * math.min(linesCovering(ctx.lines, pos), LINE_MAX_CASTERS)
	end
	if beat and score + (ctx.areaSlot and AREA_BONUS_CAP or 0) <= beat then
		return nil
	end
	if (apos or tpos) and not geo.maskSight(flags) then
		return nil
	end
	if ctx.melee then
		local boxed = ctx.minFree + 1 - geo.maskFreeNeighbours(flags)
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
--- plus the anchor's slot square (trailing: its TRAIL_RADIUS square).
local function memberCandidates(ctx)
	local out, seen = {}, {}
	local function addSquare(center, r)
		for dx = -r, r do
			for dy = -r, r do
				local x, y = center.x + dx, center.y + dy
				local key = geo.tileKey(x, y)
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
		addSquare(ctx.apos, ctx.trail and TRAIL_RADIUS or ctx.slotDist)
	end
	return out
end

--- Best candidate; nil (stay) unless it beats the current tile by TILE_MOVE_MARGIN.
--- One tile mask covers the current tile and every candidate (free, sight of the
--- anchor and target, free neighbours).
local function pickTile(ctx)
	local candidates = memberCandidates(ctx)
	candidates[#candidates + 1] = ctx.ppos
	local x1, y1, x2, y2 = geo.bounds(candidates)
	local cx, cy = math.floor((x1 + x2) / 2), math.floor((y1 + y2) / 2)
	local radius = math.max(cx - x1, x2 - cx, cy - y1, y2 - cy)
	ctx.mask = geo.tileMask(Position(cx, cy, ctx.ppos.z), radius, ctx.player, ctx.player:getInstanceId(), { ctx.apos, ctx.tpos })
	candidates[#candidates] = nil
	local here = memberTileScore(ctx, ctx.ppos)
	local best, bestScore = nil, here and (here + TILE_MOVE_MARGIN) or nil
	for _, pos in ipairs(candidates) do
		if not sameTile(pos, ctx.ppos) then
			local score = memberTileScore(ctx, pos, bestScore)
			if score then
				best, bestScore = pos, score
			end
		end
	end
	return best
end

--- Non-anchor member (fighting in formation, trailing the anchor without a target,
--- aiming an area spell): walk to the best-scoring tile when it beats staying, else
--- hold facing the target. Melee reaches its target with engine follow first. `anchor`
--- (expedition formation) and `target` are optional; without an anchor, `home` (a
--- ranged expedition anchor's fight spot) stands in for its position. Re-evaluates
--- every ADJUST_THROTTLE_MS, or at once when a monster targeting a ranged member closes
--- in or the member stands in a boss front.
local function driveMember(player, anchor, target, config, state, home)
	local ppos = player:getPosition()
	if not ppos then
		return
	end
	local apos = anchor and anchor:getPosition() or home
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
	local bosses = bossFronts(player)
	local threatened = not melee and nearestThreat(ppos, threats) < safeDist
	local unsafe = threatened or (bosses[1] ~= nil and inBossFront(player, ppos, bosses))
	if not unsafe and throttled(state, "memberEvalAt", ADJUST_THROTTLE_MS) then
		return
	end
	local directive = state and state.directive
	local ctx = {
		player = player,
		ppos = ppos,
		tpos = tpos,
		apos = apos,
		melee = melee,
		d = d,
		trail = target == nil and anchor ~= nil,
		front = directive and directive.front,
		walkCost = threatened and UNSAFE_WALK_COST or SLOT_WALK_COST,
		slotDist = slotDistanceOf(config),
		anchorLanes = not (melee and apos and chebyshev(ppos, apos) <= 1),
		threats = threats,
		safeDist = safeDist,
		bosses = bosses,
		lines = anchor and lineDanger(player) or nil,
		minFree = REPOSITION_MIN_FREE,
		wantOrthogonal = melee and tpos ~= nil and CombatAutomation.hasDirectionalAttackSlot ~= nil
			and CombatAutomation.hasDirectionalAttackSlot(config),
		dodgeBeams = melee and tpos ~= nil and directionalShape(target) ~= nil,
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
	local facePos = target and target:getPosition()
	if facePos and facePos.z == ppos.z then
		faceToward(player, facePos)
	end
end

--- Low HP (CombatAutomationConfig.isPositionCritical): step to the adjacent tile farthest
--- from fighting monsters (ties toward the leash anchor) while heals catch up.
--- True while a retreat step owns movement.
local function retreatIfCritical(player, state)
	if not state then
		return false
	end
	if not settings.isPositionCritical(player) then
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
	local anchor = player:getPathLeashAnchor()
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
		local directive = not anchor and isExpeditionAnchor(state) and state.directive
		driveMember(player, anchor, target, config, state, directive and directive.home and directive.pos or nil)
	end
end


MOVE_PRIV.driveMember = driveMember
MOVE_PRIV.applyCreatureStance = applyCreatureStance
