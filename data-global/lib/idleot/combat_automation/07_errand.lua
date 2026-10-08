-- Player errands: walk somewhere, step onto a tile, or walk up to something and use an
-- item there, as the player would by hand. While an errand runs it owns the player's
-- movement: cavebot routes, expedition hold / formation / stance and catch-up leave the
-- player alone (CombatAutomationMovement.tick, ExpeditionAI catch-up); targeting, spells
-- and healing keep running. Manual walk / follow input (idle combat) ends it.
--
-- Every errand takes `opts`:
--   ttlMs      give up after this long (default 30s)
--   onDone     fn(player, ok, reason) once it ends (player nil when gone); reason is
--              "timeout", "manual", "cancelled", "replaced", "gone", "missing" or a
--              RETURNVALUE_* of a refused use
--   keepGoing  fn(player) -> false ends it ("cancelled")
-- A player runs one errand at a time; starting another replaces it.

PlayerErrand = PlayerErrand or {}

local POLL_MS = 250
local DEFAULT_TTL_MS = 30000
local STEP_RETRY_MS = 1500

local geo = CombatGeo
local errands = {}

local DIRECTION_BY_OFFSET = {
	[-1] = { [-1] = DIRECTION_NORTHWEST, [0] = DIRECTION_WEST, [1] = DIRECTION_SOUTHWEST },
	[0] = { [-1] = DIRECTION_NORTH, [1] = DIRECTION_SOUTH },
	[1] = { [-1] = DIRECTION_NORTHEAST, [0] = DIRECTION_EAST, [1] = DIRECTION_SOUTHEAST },
}

--- True while an errand owns `player`'s movement.
function PlayerErrand.owns(player)
	return player ~= nil and errands[player:getId()] ~= nil
end

local function finish(errand, ok, reason)
	if errands[errand.playerId] ~= errand then
		return
	end
	errands[errand.playerId] = nil
	if errand.event then
		stopEvent(errand.event)
		errand.event = nil
	end
	local player = Player(errand.playerId)
	if player then
		CombatAutomationMovement.clearWalkDedupe(player)
	end
	if errand.onDone then
		local called, err = pcall(errand.onDone, player, ok, reason)
		if not called then
			logger.error("[PlayerErrand] onDone failed: {}", tostring(err))
		end
	end
end

function PlayerErrand.cancel(player, reason)
	local errand = player and errands[player:getId()]
	if errand then
		finish(errand, false, reason or "cancelled")
	end
end

local function within(player, dest, reach)
	local pos = player:getPosition()
	return pos.z == dest.z and geo.chebyshev(pos, dest) <= reach
end

--- One walk step toward the errand's spot; true once there.
local function approach(errand, player)
	if within(player, errand.dest, errand.reach) then
		return true
	end
	CombatAutomationMovement.queueWalkToward(player, errand.dest, false, true, errand.reach, true)
	return false
end

local function inInstance(player, fn)
	if Game.runInInstance and player.getInstanceId then
		return Game.runInInstance(player:getInstanceId(), fn)
	end
	return fn()
end

local function tick(errand)
	errand.event = nil
	if errands[errand.playerId] ~= errand then
		return
	end
	local player = Player(errand.playerId)
	if not player then
		return finish(errand, false, "gone")
	end
	if player.isManualControl and player:isManualControl(0) then
		return finish(errand, false, "manual")
	end
	if geo.nowMs() >= errand.deadline then
		return finish(errand, false, "timeout")
	end
	if errand.keepGoing and not errand.keepGoing(player) then
		return finish(errand, false, "cancelled")
	end
	local done, ok, reason = errand.advance(errand, player)
	if done then
		return finish(errand, ok, reason)
	end
	errand.event = addEvent(function()
		tick(errand)
	end, POLL_MS)
end

local function start(player, errand, opts)
	if not player or not errand.dest then
		return false
	end
	opts = opts or {}
	local current = errands[player:getId()]
	if current then
		finish(current, false, "replaced")
	end
	errand.playerId = player:getId()
	errand.dest = Position(errand.dest.x, errand.dest.y, errand.dest.z)
	errand.deadline = geo.nowMs() + (opts.ttlMs or DEFAULT_TTL_MS)
	errand.onDone = opts.onDone
	errand.keepGoing = opts.keepGoing
	errands[errand.playerId] = errand
	if player.getFollowCreature and player:getFollowCreature() then
		player:setFollowCreature(nil)
	end
	tick(errand)
	return true
end

--- Walk to `dest` (within `opts.reach` tiles, default 0: onto it). With
--- `opts.waitUntil(player)`, stay there until it returns true.
function PlayerErrand.walkTo(player, dest, opts)
	opts = opts or {}
	local waitUntil = opts.waitUntil
	return start(player, {
		dest = dest,
		reach = math.max(0, opts.reach or 0),
		advance = function(errand, p)
			if not approach(errand, p) then
				return false
			end
			if waitUntil and not inInstance(p, function()
				return waitUntil(p)
			end) then
				return false
			end
			return true, true
		end,
	}, opts)
end

--- Walk next to `dest` and take the last step onto it by hand: for teleports, stairs and
--- step-in tiles the pathfinder routes around. Done once the step moved the player.
function PlayerErrand.stepOnto(player, dest, opts)
	return start(player, {
		dest = dest,
		reach = 1,
		advance = function(errand, p)
			local pos = p:getPosition()
			if errand.steppedFrom then
				if not geo.sameTile(pos, errand.steppedFrom) then
					return true, true
				end
				if geo.nowMs() - errand.steppedAt < STEP_RETRY_MS then
					return false
				end
			end
			if geo.sameTile(pos, errand.dest) then
				return true, true
			end
			if not approach(errand, p) then
				errand.steppedFrom = nil
				return false
			end
			local dir = DIRECTION_BY_OFFSET[errand.dest.x - pos.x][errand.dest.y - pos.y]
			errand.steppedFrom = Position(pos.x, pos.y, pos.z)
			errand.steppedAt = geo.nowMs()
			p:autoWalk({ dir }, 0, true, true)
			return false
		end,
	}, opts)
end

--- Walk within `reach` of the use spot, face it and use: `resolve(player)` returns the item
--- (and the use-with target) at that moment. A nil item ends the errand ("missing"), or
--- with `opts.wait` keeps it waiting there.
local function useErrand(player, dest, reach, resolve, opts)
	return start(player, {
		dest = dest,
		reach = reach,
		advance = function(errand, p)
			if not approach(errand, p) then
				return false
			end
			local item, target = inInstance(p, function()
				return resolve(p)
			end)
			if not item then
				if opts.wait then
					return false
				end
				return true, false, "missing"
			end
			geo.faceToward(p, errand.dest)
			local used, ret = inInstance(p, function()
				return p:useItem(item, target)
			end)
			if used then
				return true, true
			end
			if ret == RETURNVALUE_YOUAREEXHAUSTED or ret == RETURNVALUE_TOOFARAWAY then
				return false
			end
			return true, false, ret
		end,
	}, opts)
end

local function itemOnTile(position, ids)
	local tile = Tile(position)
	if not tile then
		return nil
	end
	for _, id in ipairs(type(ids) == "table" and ids or { ids }) do
		local item = tile:getItemById(id)
		if item then
			return item
		end
	end
	return nil
end

--- Walk next to map item `itemId` (or the first present of a list of ids) at `position`
--- and use it.
function PlayerErrand.use(player, position, itemId, opts)
	opts = opts or {}
	return useErrand(player, position, 1, function()
		return itemOnTile(position, itemId)
	end, opts)
end

--- Walk next to map item `itemId` (or the first present of a list of ids) at `position`
--- and pick it up into the backpack, as a drag onto the inventory would (capacity and
--- free slots apply). Ends "missing" when the item is gone, or a refused move's reason.
function PlayerErrand.pickUp(player, position, itemId, opts)
	return start(player, {
		dest = position,
		reach = 1,
		advance = function(errand, p)
			if not approach(errand, p) then
				return false
			end
			local item = inInstance(p, function()
				return itemOnTile(position, itemId)
			end)
			if not item then
				return true, false, "missing"
			end
			if item:moveToSlot(p, CONST_SLOT_WHEREEVER) then
				return true, true
			end
			return true, false, "refused"
		end,
	}, opts)
end

--- Walk within `opts.reach` (default 1) of `position` and use carried item `itemId` on map
--- item `opts.targetId` there (an id or a list: the first present), or on the position
--- itself, as a click on that tile.
function PlayerErrand.useWith(player, itemId, position, opts)
	opts = opts or {}
	return useErrand(player, position, math.max(1, opts.reach or 1), function(p)
		local item = p:getItemById(itemId, true)
		if not item then
			return nil
		end
		if not opts.targetId then
			return item, Position(position.x, position.y, position.z)
		end
		local target = itemOnTile(position, opts.targetId)
		return target and item or nil, target
	end, opts)
end
