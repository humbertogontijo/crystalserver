-- CreatureController: idle action verbs any creature can perform.
-- PlayerController extends this. Orchestrators pick which controller acts.
-- Action backends are Lua (PlayerErrand) today; method names stay stable for C++ later.

CreatureController = CreatureController or {}
CreatureController.__index = CreatureController

local geo = CombatGeo
local byCreatureId = {}

local TELEPORT_IF_FAR = 40 -- tiles; then walk the last stretch

local function wrapOpts(self, opts)
	opts = opts or {}
	local wrapped = {}
	for k, v in pairs(opts) do
		wrapped[k] = v
	end
	local keepGoing, onDone = opts.keepGoing, opts.onDone
	wrapped.keepGoing = function(actor)
		if not self:isDriven(actor) then
			return false
		end
		if keepGoing then
			return keepGoing(actor) ~= false
		end
		return true
	end
	if onDone then
		wrapped.onDone = function(actor, ok, reason)
			onDone(actor, ok, reason)
		end
	end
	return wrapped
end

--- Resolve a live controller for `creature` (creates one if needed).
function CreatureController.get(creature)
	if not creature then
		return nil
	end
	local id = creature:getId()
	local ctrl = byCreatureId[id]
	if ctrl and ctrl.creatureId == id then
		return ctrl
	end
	ctrl = setmetatable({
		creatureId = id,
		_jobs = {},
		_running = false,
	}, CreatureController)
	byCreatureId[id] = ctrl
	return ctrl
end

function CreatureController.release(creatureId)
	byCreatureId[creatureId] = nil
end

function CreatureController:creature()
	return Creature(self.creatureId)
end

--- True while idle AI may drive this creature (override on PlayerController).
function CreatureController:isDriven(actor)
	actor = actor or self:creature()
	return actor ~= nil and actor:getHealth() > 0
end

function CreatureController:position()
	local c = self:creature()
	return c and c:getPosition() or nil
end

--- Walk toward `dest` (re-validated). Far starts teleport near dest then walk.
function CreatureController:goTo(dest, opts)
	opts = opts or {}
	if not dest then
		if opts.onDone then
			opts.onDone(nil, false, "gone")
		end
		return false
	end
	-- Errands are player-backed today; non-player creatures need a later backend.
	local player = Player(self.creatureId)
	if not player or not PlayerErrand then
		if opts.onDone then
			opts.onDone(self:creature(), false, "unsupported")
		end
		return false
	end
	dest = Position(dest.x, dest.y, dest.z)
	local here = player:getPosition()
	local dist = geo.chebyshev(here, dest)
	local farLimit = opts.noTeleport and math.huge or (opts.teleportIfFar or TELEPORT_IF_FAR)
	if not opts.noTeleport and (dist == math.huge or dist > farLimit) then
		local near = Position(dest.x, dest.y + 1, dest.z)
		player:teleportTo(near, false)
	end
	return PlayerErrand.walkTo(player, dest, wrapOpts(self, opts))
end

function CreatureController:stepOnto(dest, opts)
	local player = Player(self.creatureId)
	if not player then
		return false
	end
	return PlayerErrand.stepOnto(player, dest, wrapOpts(self, opts))
end

function CreatureController:useAt(position, itemId, opts)
	local player = Player(self.creatureId)
	if not player then
		return false
	end
	return PlayerErrand.use(player, position, itemId, wrapOpts(self, opts))
end

function CreatureController:useWith(itemId, position, opts)
	local player = Player(self.creatureId)
	if not player then
		return false
	end
	return PlayerErrand.useWith(player, itemId, position, wrapOpts(self, opts))
end

function CreatureController:pickUp(position, itemId, opts)
	local player = Player(self.creatureId)
	if not player then
		return false
	end
	return PlayerErrand.pickUp(player, position, itemId, wrapOpts(self, opts))
end

--- Hunt lure / pull toward a stand (player combat automation).
function CreatureController:lureTo(dest, opts)
	opts = opts or {}
	-- For v1, lure is "go to hold / dest"; full lure pack remains expedition hunt.
	return self:goTo(dest, opts)
end
