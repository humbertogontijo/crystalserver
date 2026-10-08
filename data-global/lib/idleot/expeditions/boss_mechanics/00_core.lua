-- Expedition boss mechanics: how an expedition party plays a lever boss's own mechanic
-- (stage puzzles, immunity breakers) in the boss's real arena, so the stock scripts run
-- the fight as in Tibia. One file per boss in this folder registers its mechanic.
--
-- A mechanic acts only through what a player could do by hand: walk (PlayerErrand), use
-- items through the engine (stock actions, routed to the fight's encounter copy), step on
-- tiles and portals, say words. Only party members the AI drives ("agents": not paused or
-- under manual control) are sent around; the others play it themselves. Bosses with a
-- mechanic keep their immunity scripts; ExpeditionBoss strips them as a fallback when the
-- boss stays immune too long (or right away for bosses without a mechanic).

ExpeditionBossMechanics = ExpeditionBossMechanics or {}
ExpeditionBossMechanics.mechanics = ExpeditionBossMechanics.mechanics or {}

local POLL_MS = 500
local CROSSING_HOLD_MS = 30000 -- catch-up teleports wait while the party walks to another floor
local SWEEP_MS = 500 -- standing goals (duties, crossings, chests) look for idle agents

local Context = {}
Context.__index = Context

function Context:live()
	if self.stopped or (self.copy and not self.copy.alive) then
		return false
	end
	local session = ExpeditionManager.getSessionByKey(self.sessionKey)
	return session ~= nil and session.state == "hunting", session
end

--- `fn()` after `delayMs`, in the instance's scope, unless the mechanic stopped.
function Context:after(delayMs, fn)
	local eventId
	eventId = addEvent(function()
		self.events[eventId] = nil
		if self:live() then
			Game.runInInstance(self.instanceId, fn)
		end
	end, delayMs)
	self.events[eventId] = true
end

--- `fn()` every `intervalMs` until the mechanic stops.
function Context:every(intervalMs, fn)
	local function step()
		fn()
		self:after(intervalMs, step)
	end
	self:after(intervalMs, step)
end

--- `fn()` now and every `intervalMs` until the mechanic stops.
function Context:sweep(intervalMs, fn)
	Game.runInInstance(self.instanceId, fn)
	self:every(intervalMs, fn)
end

local function present(self, player)
	return player:getHealth() > 0 and player:getInstanceId() == self.instanceId and not PzTeleport.isGod(player)
end

--- Party members standing in the instance (gods spectate).
function Context:players()
	local _, session = self:live()
	local players = {}
	for _, id in ipairs(session and ExpeditionManager.sessionMemberIds(session) or {}) do
		local player = Player(id)
		if player and present(self, player) then
			players[#players + 1] = player
		end
	end
	return players
end

--- True while the AI drives `player`: in the fight, not paused, not under manual control.
function Context:isAgent(player)
	local live, session = self:live()
	if not live or not player or not present(self, player) then
		return false
	end
	if session.manualIds and session.manualIds[player:getId()] then
		return false
	end
	return not CombatAutomationMovement.isManual(player)
end

--- Party members the AI moves (not paused / under manual control).
function Context:agents()
	local agents = {}
	for _, player in ipairs(self:players()) do
		if self:isAgent(player) then
			agents[#agents + 1] = player
		end
	end
	return agents
end

local function nearestOf(players, position, range)
	local best, bestDist = nil, nil
	for _, player in ipairs(players) do
		local pos = player:getPosition()
		if pos.z == position.z then
			local dist = math.max(math.abs(pos.x - position.x), math.abs(pos.y - position.y))
			if (not range or dist <= range) and (not bestDist or dist < bestDist) then
				best, bestDist = player, dist
			end
		end
	end
	return best
end

--- Party member closest to `position` on its floor (nil when none is within `range`).
function Context:nearestPlayer(position, range)
	return nearestOf(self:players(), position, range)
end

function Context:nearestAgent(position, range)
	return nearestOf(self:agents(), position, range)
end

--- Agents to send on errands, sparing the anchor (it holds the fight) unless it is alone.
function Context:runners()
	local _, session = self:live()
	local anchor = session and ExpeditionConfig.getAnchorPlayer(session)
	local agents, runners = self:agents(), {}
	for _, player in ipairs(agents) do
		if not anchor or player:getId() ~= anchor:getId() then
			runners[#runners + 1] = player
		end
	end
	if #runners == 0 then
		return agents
	end
	return runners
end

function Context:boss()
	local _, session = self:live()
	return session and ExpeditionBoss.getBoss(session) or nil
end

--- True while `monster` has the creature event `name` registered (any event type).
function ExpeditionBossMechanics.hasEvent(monster, name, eventType)
	local events = monster and monster:getEvents(eventType or CREATURE_EVENT_HEALTHCHANGE)
	if type(events) ~= "table" then
		return false
	end
	local wanted = name:lower()
	for _, registered in ipairs(events) do
		if type(registered) == "string" and registered:lower() == wanted then
			return true
		end
	end
	return false
end

function Context:bossHasEvent(eventName)
	return ExpeditionBossMechanics.hasEvent(self:boss(), eventName)
end

--- Every `intervalMs` while the bound boss has immunity event `eventName`: `fn(boss)`.
function Context:whileBossHasEvent(eventName, intervalMs, fn)
	self:every(intervalMs, function()
		local boss = self:boss()
		if boss and ExpeditionBossMechanics.hasEvent(boss, eventName) then
			fn(boss)
		end
	end)
end

--- Positions of the arena (lever zone) whose ground or items match `predicate(item)`.
function Context:findArenaTiles(predicate)
	local found = {}
	local positions = self.lever and self.lever:getZone():getPositions() or {}
	Game.runInInstance(self.instanceId, function()
		for _, position in ipairs(positions) do
			local tile = Tile(position)
			if tile then
				local ground = tile:getGround()
				local match = ground and predicate(ground)
				if not match then
					for _, item in ipairs(tile:getItems() or {}) do
						if predicate(item) then
							match = true
							break
						end
					end
				end
				if match then
					found[#found + 1] = Position(position.x, position.y, position.z)
				end
			end
		end
	end)
	return found
end

-- Errands (PlayerErrand) that end with the mechanic, or once the player is paused or taken
-- over by hand; keepGoing / onDone run in the instance's scope.

function Context:errandOpts(opts)
	opts = opts or {}
	local wrapped = {}
	for key, value in pairs(opts) do
		wrapped[key] = value
	end
	local keepGoing, onDone, waitUntil = opts.keepGoing, opts.onDone, opts.waitUntil
	wrapped.keepGoing = function(player)
		if not self:isAgent(player) then
			return false
		end
		return not keepGoing or Game.runInInstance(self.instanceId, keepGoing, player)
	end
	if waitUntil then
		wrapped.waitUntil = function(player)
			return Game.runInInstance(self.instanceId, waitUntil, player)
		end
	end
	wrapped.onDone = onDone and function(player, ok, reason)
		if self:live() then
			Game.runInInstance(self.instanceId, onDone, player, ok, reason)
		end
	end or nil
	return wrapped
end

function Context:walkTo(player, dest, opts)
	return PlayerErrand.walkTo(player, dest, self:errandOpts(opts))
end

function Context:stepOnto(player, dest, opts)
	return PlayerErrand.stepOnto(player, dest, self:errandOpts(opts))
end

function Context:use(player, position, itemId, opts)
	return PlayerErrand.use(player, position, itemId, self:errandOpts(opts))
end

function Context:useWith(player, itemId, position, opts)
	return PlayerErrand.useWith(player, itemId, position, self:errandOpts(opts))
end

function Context:pickUp(player, position, itemId, opts)
	return PlayerErrand.pickUp(player, position, itemId, self:errandOpts(opts))
end

--- Run `job(player, done)` for `player` after its earlier jobs, in order (never before the
--- next tick, and only while the AI drives the player: paused or under manual control, its
--- jobs wait); the job calls `done()` once finished (typically from an errand's onDone).
--- `onDrop()` runs instead of the job when it is dropped unrun (the player logged out).
function Context:queue(player, job, onDrop)
	local id = player:getId()
	local jobs = self.jobs[id]
	if not jobs then
		jobs = {}
		self.jobs[id] = jobs
	end
	jobs[#jobs + 1] = { run = job, drop = onDrop }
	self:after(0, function()
		self:runJob(id)
	end)
end

function Context:runJob(id)
	local jobs = self.jobs[id]
	local job = jobs and jobs[1]
	if self.running[id] or not job or not self:live() then
		return
	end
	local player = Player(id)
	if player and not self:isAgent(player) then
		self:after(SWEEP_MS, function()
			self:runJob(id)
		end)
		return
	end
	self.running[id] = true
	local finished = false
	local function done()
		if finished then
			return
		end
		finished = true
		table.remove(jobs, 1)
		self.running[id] = nil
		if jobs[1] then
			self:after(0, function()
				self:runJob(id)
			end)
		end
	end
	if not player then
		if job.drop then
			pcall(job.drop)
		end
		return done()
	end
	local ok, err = pcall(job.run, player, done)
	if not ok then
		logger.error("[ExpeditionBossMechanics] {}: job failed: {}", self.name, tostring(err))
		done()
	end
end

--- While `active()` holds, every agent keeps `job(player, done)` going: it is queued again
--- each time the previous run finished, so members taken over by hand (or paused) pick
--- their duty back up once the AI drives them again.
function Context:duty(active, job)
	local busy = {}
	self:sweep(SWEEP_MS, function()
		if not active() then
			return
		end
		for _, player in ipairs(self:agents()) do
			local id = player:getId()
			if not busy[id] then
				busy[id] = true
				self:queue(player, function(p, done)
					local finished = false
					local function release()
						if not finished then
							finished = true
							busy[id] = nil
							done()
						end
					end
					if not active() then
						return release()
					end
					job(p, release)
				end, function()
					busy[id] = nil
				end)
			end
		end
	end)
end

--- From now on every agent not yet `across(position)` walks onto `portal` (a teleport or
--- stairs into the next area) after its queued jobs; members taken over by hand join once
--- the AI drives them again. Catch-up teleports wait until the anchor and every agent are
--- across; the anchor then holds where it landed.
function Context:crossParty(portal, across)
	local crossing, held = {}, false
	local function arrived(player)
		return across(player:getPosition())
	end
	self:sweep(SWEEP_MS, function()
		local _, session = self:live()
		if not session then
			return
		end
		local anchor = ExpeditionConfig.getAnchorPlayer(session)
		local pending = anchor ~= nil and not arrived(anchor)
		if anchor and not pending and not held then
			held = true
			local pos = anchor:getPosition()
			session.holdPos = Position(pos.x, pos.y, pos.z)
		end
		for _, player in ipairs(self:agents()) do
			local id = player:getId()
			if not arrived(player) then
				pending = true
				if not crossing[id] then
					crossing[id] = true
					self:queue(player, function(p, done)
						if arrived(p) then
							crossing[id] = nil
							return done()
						end
						self:stepOnto(p, portal, {
							onDone = function(_, ok, reason)
								if not ok then
									logger.info("[ExpeditionBossMechanics] {}: {} did not cross ({}), retrying", self.name, p:getName(), tostring(reason))
								end
								crossing[id] = nil
								done()
							end,
						})
					end, function()
						crossing[id] = nil
					end)
				end
			end
		end
		if pending then
			session.catchUpHeldUntil = CombatGeo.nowMs() + CROSSING_HOLD_MS
		end
	end)
end

-- Encounter copy helpers (mechanics of bosses run by a stock Encounter script).

function Context:stage()
	return self.copy and self.copy.encounter.currentStage or nil
end

--- Once the encounter enters `stage`, wait `delayMs` and run `fn`.
function Context:onStage(stage, delayMs, fn)
	local function poll()
		if self:stage() == stage then
			self:after(delayMs, fn)
		else
			self:after(POLL_MS, poll)
		end
	end
	poll()
end

--- Every agent on its floor opens each chest of `itemIds` the stock script places (stage
--- rewards) once, before its next move; members taken over by hand open it once the AI
--- drives them again.
function Context:rewardChests(itemIds)
	if not self.copy then
		return
	end
	local wanted, chests = {}, {}
	for _, id in ipairs(itemIds) do
		wanted[id] = true
	end
	local function sweep()
		for _, chest in ipairs(chests) do
			for _, player in ipairs(self:agents()) do
				local id = player:getId()
				if not chest.opened[id] and not chest.queued[id] and player:getPosition().z == chest.position.z then
					chest.queued[id] = true
					self:queue(player, function(p, done)
						if p:getPosition().z ~= chest.position.z then
							chest.queued[id] = nil
							return done()
						end
						self:use(p, chest.position, chest.itemId, {
							onDone = function(_, ok, reason)
								chest.queued[id] = nil
								if ok or reason ~= "manual" then
									chest.opened[id] = true
									logger.info("[ExpeditionBossMechanics] {}: {} reward chest {}", self.name, p:getName(), ok and "opened" or ("not opened (" .. tostring(reason) .. ")"))
								end
								done()
							end,
						})
					end, function()
						chest.queued[id] = nil
					end)
				end
			end
		end
	end
	EncounterInstances.watchItems(self.copy, function(item)
		local itemId = item:getId()
		if wanted[itemId] then
			chests[#chests + 1] = { itemId = itemId, position = item:getPosition(), opened = {}, queued = {} }
			sweep()
		end
	end)
	self:every(SWEEP_MS, sweep)
end

--- `mechanic(ctx)` plays boss `name`'s mechanic (boss name, or encounter name for
--- encounter-run fights) in expeditions.
function ExpeditionBossMechanics.register(name, mechanic)
	ExpeditionBossMechanics.mechanics[name:lower()] = { name = name, run = mechanic }
end

local function mechanicOf(lever)
	if not lever then
		return nil
	end
	local mechanics = ExpeditionBossMechanics.mechanics
	return (lever.encounter and mechanics[lever.encounter:lower()]) or (lever.name and mechanics[lever.name:lower()])
end

--- True when the session's boss fight has a mechanic (immunity is part of the fight).
function ExpeditionBossMechanics.handles(lever)
	return mechanicOf(lever) ~= nil
end

--- Start the mechanic of the session's lever boss. `copy`: the fight's encounter copy, if any.
function ExpeditionBossMechanics.start(session, lever, copy)
	ExpeditionBossMechanics.stop(session)
	local mechanic = mechanicOf(lever)
	if not mechanic then
		return false
	end
	local ctx = setmetatable({
		name = mechanic.name,
		sessionKey = session.key,
		instanceId = session.instance.instanceId,
		lever = lever,
		copy = copy,
		events = {},
		jobs = {},
		running = {},
	}, Context)
	session.bossMechanic = ctx
	local ok, err = pcall(mechanic.run, ctx)
	if not ok then
		logger.error("[ExpeditionBossMechanics] {} failed to start: {}", mechanic.name, tostring(err))
	end
	return ok
end

--- Stop the session's mechanic; its errands end on their next step.
function ExpeditionBossMechanics.stop(session)
	local ctx = session and session.bossMechanic
	if not ctx then
		return
	end
	session.bossMechanic = nil
	session.catchUpHeldUntil = nil
	ctx.stopped = true
	for eventId in pairs(ctx.events) do
		stopEvent(eventId)
	end
	ctx.events = {}
	ctx.jobs = {}
	ctx.running = {}
end
