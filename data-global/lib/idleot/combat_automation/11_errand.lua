-- Player errands: walk somewhere, step onto a tile, or walk up to something and use an
-- item there, as the player would by hand. While an errand runs it owns the player's
-- movement: cavebot routes, expedition hold / formation / stance and catch-up leave the
-- player alone (CombatAutomationMovement.tick, ExpeditionAI catch-up); targeting, spells
-- and healing keep running. Manual walk / follow input (idle combat) ends it.
--
-- An errand advances on the player's think (playerOnIdleCombatThink / playerOnThink) and as
-- soon as its walk ends (player.walkDone); a timer at its ttl ends it ("gone" when the
-- player logged out meanwhile). Start errands from the player's instance (scripts and boss
-- mechanics run there).
--
-- Every errand takes `opts`:
--   ttlMs      give up after this long (default 30s)
--   onDone     fn(player, ok, reason) once it ends (player nil when gone); reason is
--              "timeout", "manual", "cancelled", "replaced", "gone", "blocked" (no path),
--              "missing", "refused" or a RETURNVALUE_* of a refused use
--   keepGoing  fn(player) -> false ends it ("cancelled")
-- A player runs one errand at a time; starting another replaces it.

PlayerErrand = PlayerErrand or {}

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
	stopEvent(errand.deadlineEvent)
	local player = Player(errand.playerId)
	if player then
		CombatAutomationMovement.clearPendingWalkAction(player)
	end
	if errand.onDone then
		local called, err = pcall(errand.onDone, player, ok, reason)
		if not called then
			logger.error("[PlayerErrand] onDone failed: {}", tostring(err))
		end
	end
end

--- One walk toward the errand's spot: true once within [minReach, reach] of it; false,
--- "blocked" while path searches keep finding nothing.
local function approach(errand, player)
	local dist = geo.chebyshev(player:getPosition(), errand.dest)
	if dist >= errand.minReach and dist <= errand.reach then
		return true
	end
	CombatAutomationMovement.queueWalkToward(player, errand.dest, false, true, errand.reach, true, errand.minReach)
	if CombatAutomationMovement.walkBlocked(player, errand.dest) then
		return false, "blocked"
	end
	return false
end

--- Walk until there: nil while walking, else the advance result for a blocked walk.
local function walkThere(errand, player)
	local there, blocked = approach(errand, player)
	if there then
		return nil
	end
	if blocked then
		return true, false, blocked
	end
	return false
end

local function step(errand, player)
	if errands[errand.playerId] ~= errand then
		return
	end
	if CombatAutomationMovement.isManual(player, errand.startedAt) then
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
end

--- Advance `player`'s errand (its think and the end of its walks call this).
function PlayerErrand.think(player)
	local errand = player and errands[player:getId()]
	if errand then
		step(errand, player)
	end
end

IdleEvents.on("player.walkDone", PlayerErrand.think, "PlayerErrand")

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
	errand.minReach = math.min(errand.minReach or 0, errand.reach)
	local ttlMs = opts.ttlMs or DEFAULT_TTL_MS
	errand.startedAt = geo.nowMs()
	errand.deadline = errand.startedAt + ttlMs
	errand.onDone = opts.onDone
	errand.keepGoing = opts.keepGoing
	errands[errand.playerId] = errand
	if player:getFollowCreature() then
		player:setFollowCreature(nil)
	end
	errand.deadlineEvent = addEvent(function()
		finish(errand, false, Player(errand.playerId) and "timeout" or "gone")
	end, ttlMs)
	step(errand, player)
	return true
end

--- Walk to `dest`: within `opts.reach` tiles (default 0: onto it) and at least
--- `opts.minReach` away (default 0). With `opts.waitUntil(player)`, stay there until it
--- returns true.
function PlayerErrand.walkTo(player, dest, opts)
	opts = opts or {}
	local waitUntil = opts.waitUntil
	return start(player, {
		dest = dest,
		reach = math.max(0, opts.reach or 0),
		minReach = math.max(0, opts.minReach or 0),
		advance = function(errand, p)
			local walking, ok, reason = walkThere(errand, p)
			if walking ~= nil then
				return walking, ok, reason
			end
			if waitUntil and not waitUntil(p) then
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
			local walking, ok, reason = walkThere(errand, p)
			if walking ~= nil then
				errand.steppedFrom = nil
				return walking, ok, reason
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
			local walking, ok, reason = walkThere(errand, p)
			if walking ~= nil then
				return walking, ok, reason
			end
			local item, target = resolve(p)
			if not item then
				if opts.wait then
					return false
				end
				return true, false, "missing"
			end
			geo.faceToward(p, errand.dest)
			local used, ret = p:useItem(item, target)
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
--- free slots apply). Ends "missing" when the item is gone, or "refused".
function PlayerErrand.pickUp(player, position, itemId, opts)
	return start(player, {
		dest = position,
		reach = 1,
		advance = function(errand, p)
			local walking, ok, reason = walkThere(errand, p)
			if walking ~= nil then
				return walking, ok, reason
			end
			local item = itemOnTile(position, itemId)
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
