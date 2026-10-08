-- Anchor fight spot: one terrain score shared by the runtime halt pick
-- (CombatAutomationMovement.bestAnchorSpot) and hunt generation, which loads this
-- file through lupa to place the cave route holds
-- (packages/asset-pipeline features/expedition/crystal/lua_anchor_spot.py).
-- Pure Lua (5.1 - 5.4): no engine API, tiles come through `env` callbacks.
--
-- Room for the monster ring around the anchor first, then a cast slot for every
-- member on one side of the box (members never trapped across it), the more
-- cardinal lanes the better; walking steps from the search origin break ties.
--
-- env = {
--   standable = function(x, y) -> bool,          -- ground a player can fight on
--   sightClear = function(x, y, tx, ty) -> bool,  -- optional (default: clear)
--   adjust = function(x, y) -> number,            -- optional score added per tile
--   passable = function(x, y) -> bool,            -- optional: tiles the search walks
--                                                 -- over and picks (default standable;
--                                                 -- the ring still counts standable)
-- }

AnchorSpot = AnchorSpot or {}

--- Per standable neighbour (room for the monster ring, up to 8): the leading term.
--- One tile outweighs the whole team term (walkway + slots + lanes, down to every
--- member unserved, for up to 5 members) plus walking steps, so the team only
--- breaks ties between tiles with the same ring.
AnchorSpot.RING_TILE = 250
--- Per standable tile at distance 2 (walkway around the box).
AnchorSpot.WALKWAY_TILE = 2
--- Per member with a slot at its slot distance, in sight of the anchor...
AnchorSpot.MEMBER_SLOT = 10
--- ...on a cardinal lane (wave / beam line through the box).
AnchorSpot.MEMBER_LANE = 4
--- Per cardinal lane open at the farthest slot distance (ranged formation, up to 4).
AnchorSpot.LANE_SLOT = 5
--- Per member left without a slot.
AnchorSpot.UNSERVED_PENALTY = 15
--- Per walking step from the search origin.
AnchorSpot.WALK_STEP = 1
--- Slot distances (stance distance + 1) hunt generation plans for: a full party of
--- four ranged members around a melee anchor.
AnchorSpot.DEFAULT_TEAM = { 4, 4, 4, 4 }

local NEIGHBOURS = {
	{ 0, -1 },
	{ 1, 0 },
	{ 0, 1 },
	{ -1, 0 },
	{ 1, -1 },
	{ 1, 1 },
	{ -1, 1 },
	{ -1, -1 },
}
local CARDINALS = { { 0, -1 }, { 1, 0 }, { 0, 1 }, { -1, 0 } }

local function tileKey(x, y)
	return x * 65536 + y
end
AnchorSpot.tileKey = tileKey

--- Search inputs: memoized `standable`, team slot distances (`team`, at least 2 each,
--- farthest first) and the score bound of the team term.
function AnchorSpot.context(env, team)
	local raw, memo = env.standable, {}
	local ctx = {
		standable = function(x, y)
			local k = tileKey(x, y)
			local v = memo[k]
			if v == nil then
				v = raw(x, y) and true or false
				memo[k] = v
			end
			return v
		end,
		sightClear = env.sightClear,
		adjust = env.adjust,
		passable = env.passable,
		team = {},
		maxSlot = 2,
	}
	for _, d in ipairs(team or {}) do
		local slot = math.max(2, math.floor(tonumber(d) or 2))
		ctx.team[#ctx.team + 1] = slot
		ctx.maxSlot = math.max(ctx.maxSlot, slot)
	end
	table.sort(ctx.team, function(a, b)
		return a > b
	end)
	ctx.teamBound = 16 * AnchorSpot.WALKWAY_TILE
		+ #ctx.team * (AnchorSpot.MEMBER_SLOT + AnchorSpot.MEMBER_LANE)
		+ (#ctx.team > 0 and 4 * AnchorSpot.LANE_SLOT or 0)
	return ctx
end

local function ringAt(standable, px, py)
	local ring = 0
	for _, off in ipairs(NEIGHBOURS) do
		if standable(px + off[1], py + off[2]) then
			ring = ring + 1
		end
	end
	return ring
end

--- Room for the team around a box at (px, py): walkway tiles at distance 2, then the
--- best side of the box (the ring of standable tiles outside the 3x3, up to
--- maxSlot + 2 away, split where walls seal it): per member (farthest slot first) the
--- best distinct slot on that side at its slot distance, in sight of (px, py), plus
--- each cardinal lane open there at the farthest slot distance. Returns score, unserved.
local function teamScore(ctx, px, py)
	local standable = ctx.standable
	local walkway = 0
	for dx = -2, 2 do
		for dy = -2, 2 do
			if (dx == -2 or dx == 2 or dy == -2 or dy == 2) and standable(px + dx, py + dy) then
				walkway = walkway + 1
			end
		end
	end
	local score = walkway * AnchorSpot.WALKWAY_TILE
	local team = ctx.team
	if #team == 0 then
		return score, 0
	end

	local radius = ctx.maxSlot + 2
	local function open(x, y)
		local dx, dy = math.abs(x - px), math.abs(y - py)
		return (dx > 1 or dy > 1) and dx <= radius and dy <= radius and standable(x, y)
	end
	local sideAt, sides = {}, 0
	local function sideOf(x, y)
		local k = tileKey(x, y)
		if sideAt[k] then
			return sideAt[k]
		end
		sides = sides + 1
		sideAt[k] = sides
		local queue, head = { x, y }, 1
		while queue[head] do
			local cx, cy = queue[head], queue[head + 1]
			head = head + 2
			for _, off in ipairs(NEIGHBOURS) do
				local nx, ny = cx + off[1], cy + off[2]
				local nk = tileKey(nx, ny)
				if not sideAt[nk] and open(nx, ny) then
					sideAt[nk] = sides
					queue[#queue + 1] = nx
					queue[#queue + 1] = ny
				end
			end
		end
		return sides
	end
	local sightClear, sightAt = ctx.sightClear, {}
	local function slotUsable(x, y, side)
		if not open(x, y) or sideOf(x, y) ~= side then
			return false
		end
		if not sightClear then
			return true
		end
		local k = tileKey(x, y)
		local v = sightAt[k]
		if v == nil then
			v = sightClear(x, y, px, py) and true or false
			sightAt[k] = v
		end
		return v
	end

	local function sideValue(side)
		local taken, value, unserved = {}, 0, 0
		for _, d in ipairs(team) do
			local bestKey, bestValue
			for dx = -d, d do
				for dy = -d, d do
					if math.abs(dx) == d or math.abs(dy) == d then
						local x, y = px + dx, py + dy
						local k = tileKey(x, y)
						local v = AnchorSpot.MEMBER_SLOT + (((dx == 0) ~= (dy == 0)) and AnchorSpot.MEMBER_LANE or 0)
						if (not bestValue or v > bestValue) and not taken[k] and slotUsable(x, y, side) then
							bestKey, bestValue = k, v
						end
					end
				end
			end
			if bestKey then
				taken[bestKey] = true
				value = value + bestValue
			else
				unserved = unserved + 1
				value = value - AnchorSpot.UNSERVED_PENALTY
			end
		end
		local d = ctx.maxSlot
		for _, off in ipairs(CARDINALS) do
			if slotUsable(px + off[1] * d, py + off[2] * d, side) then
				value = value + AnchorSpot.LANE_SLOT
			end
		end
		return value, unserved
	end

	local tried, bestValue, bestUnserved = {}, nil, #team
	for dx = -radius, radius do
		for dy = -radius, radius do
			local x, y = px + dx, py + dy
			if open(x, y) then
				local side = sideOf(x, y)
				if not tried[side] then
					tried[side] = true
					local value, unserved = sideValue(side)
					if not bestValue or value > bestValue then
						bestValue, bestUnserved = value, unserved
					end
				end
			end
		end
	end
	if not bestValue then
		return score - #team * AnchorSpot.UNSERVED_PENALTY, #team
	end
	return score + bestValue, bestUnserved
end

--- Score of the anchor standing on (x, y), `steps` walking steps from the search
--- origin. Nil when it does not score above `beat` (the team term is skipped once
--- the cheap terms already lose). Returns score, ring, unserved.
function AnchorSpot.score(ctx, x, y, steps, beat)
	local ring = ringAt(ctx.standable, x, y)
	local score = ring * AnchorSpot.RING_TILE - steps * AnchorSpot.WALK_STEP
	if ctx.adjust then
		score = score + (tonumber(ctx.adjust(x, y)) or 0)
	end
	if beat and score + ctx.teamBound <= beat then
		return nil
	end
	local team, unserved = teamScore(ctx, x, y)
	score = score + team
	if beat and score <= beat then
		return nil
	end
	return score, ring, unserved
end

--- Best scoring passable tile within `maxSteps` walking steps (8-connected, over
--- passable tiles) of (ox, oy); ties go to the nearer tile. `exclude`: set of
--- `tileKey` keys never picked. Returns x, y, score, ring, unserved (nil: none).
function AnchorSpot.best(ctx, ox, oy, maxSteps, exclude)
	local standable = ctx.standable
	if ctx.passable then
		local passable = ctx.passable
		standable = function(x, y)
			return ctx.standable(x, y) and passable(x, y)
		end
	end
	exclude = exclude or {}
	local bx, by, bestScore, bestRing, bestUnserved
	local function consider(x, y, steps)
		if exclude[tileKey(x, y)] then
			return
		end
		local score, ring, unserved = AnchorSpot.score(ctx, x, y, steps, bestScore)
		if score then
			bx, by, bestScore, bestRing, bestUnserved = x, y, score, ring, unserved
		end
	end
	if standable(ox, oy) then
		consider(ox, oy, 0)
	end
	local seen = { [tileKey(ox, oy)] = true }
	local frontier = { { ox, oy } }
	for steps = 1, math.max(0, math.floor(tonumber(maxSteps) or 0)) do
		local nextFrontier = {}
		for _, from in ipairs(frontier) do
			for _, off in ipairs(NEIGHBOURS) do
				local x, y = from[1] + off[1], from[2] + off[2]
				local k = tileKey(x, y)
				if not seen[k] then
					seen[k] = true
					if standable(x, y) then
						nextFrontier[#nextFrontier + 1] = { x, y }
						consider(x, y, steps)
					end
				end
			end
		end
		frontier = nextFrontier
	end
	return bx, by, bestScore, bestRing, bestUnserved
end
