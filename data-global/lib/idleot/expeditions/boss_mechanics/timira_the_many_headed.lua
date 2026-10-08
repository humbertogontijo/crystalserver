-- Timira the Many-Headed (Marapur), run by the stock encounter script.
-- Stage 1: everyone picks up a bucket from the nearest bucket spot, fills it at the shallow
-- water while it sparkles and pours it on the shattered water, until the water takes shape.
-- Stage 2: everyone opens the reward chest and walks through the portal, then uses the
-- corrupted water (stock cooldown 8s per player) until the next portal opens.
-- Boss: everyone opens the second chest and walks through the portal into Timira's room.
-- Points, cooldowns and stage changes stay in the stock script. Each step is a standing
-- duty: a member taken over by hand (or paused) resumes it once the AI drives it again.

local FIRST_STAGE, SECOND_STAGE, BOSS_STAGE = 3, 5, 7 -- encounter stages
local EMPTY_BUCKET, BAD_WATER_BUCKET, SPARKLING_BUCKET = 39242, 39243, 39244
local BUCKETS = { EMPTY_BUCKET, BAD_WATER_BUCKET, SPARKLING_BUCKET }
local BUCKET_SPOTS = {
	Position(33796, 32685, 10),
	Position(33797, 32691, 10),
	Position(33787, 32687, 10),
	Position(33785, 32676, 10),
}
local SHALLOW_WATER = {
	Position(33793, 32679, 10),
	Position(33794, 32679, 10),
	Position(33793, 32680, 10),
	Position(33794, 32680, 10),
	Position(33795, 32680, 10),
	Position(33793, 32681, 10),
	Position(33794, 32681, 10),
	Position(33795, 32681, 10),
	Position(33796, 32681, 10),
	Position(33794, 32682, 10),
	Position(33795, 32682, 10),
	Position(33796, 32682, 10),
	Position(33794, 32683, 10),
	Position(33795, 32683, 10),
	Position(33796, 32683, 10),
}
local SPARKLES = { 1722, 1723 }
local SHATTERED_WATER, SHATTERED_WATER_POS = 39269, Position(33798, 32689, 10)
-- The map's corrupted water lies just south of the stock fight zone (no zone query finds it).
local CORRUPTED_WATER, CORRUPTED_WATER_POS = 39267, Position(33797, 32712, 9)
local REWARD_CHEST = 39390
local FIRST_PORTAL, SECOND_PORTAL = Position(33787, 32699, 10), Position(33804, 32704, 9)
local CORRUPTED_WATER_COOLDOWN_MS = 8500 -- stock: 8s per player between uses
local PORTAL_DELAY_MS = 2000
local WATER_WALK_TTL_MS = 15000 -- walking plus waiting for the next sparkle (every ~8s)
local RETRY_MS = 1000 -- after a failed round (blocked path, refused use)

local function nearest(positions, from)
	local best, bestDist = nil, nil
	for _, pos in ipairs(positions) do
		local dist = math.max(math.abs(pos.x - from.x), math.abs(pos.y - from.y))
		if pos.z == from.z and (not bestDist or dist < bestDist) then
			best, bestDist = pos, dist
		end
	end
	return best
end

local function within(player, position, range)
	local pos = player:getPosition()
	return pos.z == position.z and math.max(math.abs(pos.x - position.x), math.abs(pos.y - position.y)) <= range
end

local function dropPosition(positions, position)
	for index, pos in ipairs(positions) do
		if pos.x == position.x and pos.y == position.y and pos.z == position.z then
			table.remove(positions, index)
			return
		end
	end
end

local function sparkling(position)
	local tile = Tile(position)
	for _, id in ipairs(SPARKLES) do
		if tile and tile:getItemById(id) then
			return true
		end
	end
	return false
end

--- Bucket spots that still hold the empty bucket the stock fight lays out.
local function bucketsLeft()
	local spots = {}
	for _, pos in ipairs(BUCKET_SPOTS) do
		local tile = Tile(pos)
		if tile and tile:getItemById(EMPTY_BUCKET) then
			spots[#spots + 1] = pos
		end
	end
	return spots
end

local function dropBuckets(player)
	for _, id in ipairs(BUCKETS) do
		local count = player:getItemCount(id)
		if count > 0 then
			player:removeItem(id, count)
		end
	end
end

--- One bucket step for `player`: fetch a bucket, fill it at the sparkling water, pour it
--- on the shattered water or empty a bad one. Whatever bucket the player carries (also
--- one picked up by hand) decides the step.
local function bucketRound(ctx, p, done)
	local function finished(_, ok)
		if ok then
			return done()
		end
		ctx:after(RETRY_MS, done)
	end
	if p:getItemCount(SPARKLING_BUCKET) > 0 then
		ctx:useWith(p, SPARKLING_BUCKET, SHATTERED_WATER_POS, { targetId = SHATTERED_WATER, onDone = finished })
	elseif p:getItemCount(BAD_WATER_BUCKET) > 0 then
		ctx:useWith(p, BAD_WATER_BUCKET, p:getPosition(), { onDone = finished })
	elseif p:getItemCount(EMPTY_BUCKET) > 0 then
		local water = nearest(ctx.reachableWater, p:getPosition())
		ctx:walkTo(p, water, {
			reach = 1,
			ttlMs = WATER_WALK_TTL_MS,
			waitUntil = function()
				return sparkling(water) or ctx:stage() ~= FIRST_STAGE
			end,
			onDone = function(_, ok, reason)
				if reason == "timeout" and #ctx.reachableWater > 1 and not within(p, water, 1) then
					dropPosition(ctx.reachableWater, water)
				end
				if not ok or ctx:stage() ~= FIRST_STAGE then
					return finished(nil, ok)
				end
				ctx:useWith(p, EMPTY_BUCKET, water, { targetId = SPARKLES, onDone = finished })
			end,
		})
	else
		local spot = nearest(bucketsLeft(), p:getPosition())
		if not spot then
			return ctx:after(RETRY_MS, done)
		end
		ctx:pickUp(p, spot, EMPTY_BUCKET, { onDone = finished })
	end
end

local function pastFirstPortal(position)
	return position.z == SECOND_PORTAL.z
end

local function pastSecondPortal(position)
	return position.z == SECOND_PORTAL.z and position.x > SECOND_PORTAL.x + 1
end

--- One use of the corrupted water, at most once per stock cooldown per player (members
--- still on the first floor wait for their crossing).
local function corruptedWaterRound(ctx, p, done)
	local id = p:getId()
	if not pastFirstPortal(p:getPosition()) or CombatGeo.nowMs() < (ctx.corruptedWaterReady[id] or 0) then
		return ctx:after(RETRY_MS, done)
	end
	ctx:use(p, CORRUPTED_WATER_POS, CORRUPTED_WATER, {
		onDone = function(_, ok)
			ctx.corruptedWaterReady[id] = CombatGeo.nowMs() + (ok and CORRUPTED_WATER_COOLDOWN_MS or RETRY_MS)
			done()
		end,
	})
end

ExpeditionBossMechanics.register("Timira the Many-Headed", function(ctx)
	ctx:rewardChests({ REWARD_CHEST })
	ctx.reachableWater = {}
	for index, position in ipairs(SHALLOW_WATER) do
		ctx.reachableWater[index] = position
	end
	ctx.corruptedWaterReady = {}
	local function inStage(stage)
		return function()
			return ctx:stage() == stage
		end
	end
	ctx:onStage(FIRST_STAGE, 3000, function()
		ctx:duty(inStage(FIRST_STAGE), function(p, done)
			bucketRound(ctx, p, done)
		end)
	end)
	ctx:onStage(SECOND_STAGE, PORTAL_DELAY_MS, function()
		for _, player in ipairs(ctx:players()) do
			dropBuckets(player)
		end
		ctx:crossParty(FIRST_PORTAL, pastFirstPortal)
		ctx:duty(inStage(SECOND_STAGE), function(p, done)
			corruptedWaterRound(ctx, p, done)
		end)
	end)
	ctx:onStage(BOSS_STAGE, PORTAL_DELAY_MS, function()
		ctx:crossParty(SECOND_PORTAL, pastSecondPortal)
	end)
end)
