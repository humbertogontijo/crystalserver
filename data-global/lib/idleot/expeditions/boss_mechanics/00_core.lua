-- Expedition boss mechanics: how an expedition party plays a lever boss's own mechanic
-- (stage puzzles, immunity breakers) in the boss's real arena, so the stock scripts run
-- the fight as in Tibia. One file per boss in this folder registers its mechanic.
--
-- A mechanic acts only through what a player could do by hand: walk (PlayerErrand), use
-- items through the engine (stock actions, routed to the fight's encounter copy), step on
-- tiles and portals, say words. Only party members the AI drives ("agents": not paused or
-- under manual control) are sent around; the others play it themselves. Bosses with a
-- mechanic keep the immunity events they declare (register opts.immunity); ExpeditionBoss
-- strips them as a fallback when the boss stays immune too long (or right away for bosses
-- without a mechanic).
--
-- A mechanic reacts to what the fight does (IdleEvents): stage changes (onStage), immunity
-- events on the boss (onBossEvent / whileBossHasEvent), items the encounter script creates
-- (onItemCreated). Its timers and subscriptions live in a child of the session's Scope and
-- end with the fight. Standing goals (duty, crossParty, rewardChests) and queued jobs share
-- one tick, and run at once when a paused member is handed back to the AI.

ExpeditionBossMechanics = ExpeditionBossMechanics or {}
ExpeditionBossMechanics.mechanics = ExpeditionBossMechanics.mechanics or {}

local CROSSING_HOLD_MS = 30000 -- catch-up teleports wait while the party walks to another floor
local TICK_MS = 500 -- standing goals look for idle agents; queued jobs of members driven again

local immunityEvents = {} -- lowercased creature event name -> true

local Context = {}
Context.__index = Context

--- True while the fight runs (session hunting, encounter copy alive); also returns the session.
function Context:live()
	return self.scope:alive(), self.session
end

--- `fn()` after `delayMs`, in the instance, unless the mechanic stopped.
function Context:after(delayMs, fn)
	return self.scope:after(delayMs, fn)
end

--- `fn()` every `intervalMs` until the mechanic stops (`name` replaces a loop of that name).
function Context:every(intervalMs, fn, name)
	return self.scope:every(intervalMs, fn, name)
end

--- `fn()` now and every `intervalMs` until the mechanic stops.
function Context:sweep(intervalMs, fn)
	return self.scope:sweep(intervalMs, fn)
end

--- IdleEvents subscription for the mechanic's lifetime.
function Context:on(event, fn)
	return self.scope:on(event, fn)
end

local function present(self, player)
	return player:getHealth() > 0 and player:getInstanceId() == self.instanceId and not PzTeleport.isGod(player)
end

--- Party members standing in the instance (gods spectate).
function Context:players()
	if not self:live() then
		return {}
	end
	return ExpeditionManager.onlinePlayers(self.session, function(player)
		return present(self, player)
	end)
end

--- True while the AI drives `player`: in the fight, not paused, not under manual control.
function Context:isAgent(player)
	if not player or not self:live() or not present(self, player) then
		return false
	end
	local manual = self.session.manualIds
	if manual and manual[player:getId()] then
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
		local dist = CombatGeo.chebyshev(player:getPosition(), position)
		if dist ~= math.huge and (not range or dist <= range) and (not bestDist or dist < bestDist) then
			best, bestDist = player, dist
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
	local anchor = self:live() and ExpeditionConfig.getAnchorPlayer(self.session)
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
	return self:live() and ExpeditionBoss.getBoss(self.session) or nil
end

--- True while `monster` has the creature event `name` registered (HEALTHCHANGE unless `eventType`).
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

--- `onAdded(monster)` (next tick) whenever a monster of the fight gains creature event
--- `eventName`, and right away for the bound boss when it already has it (bosses can spawn
--- with it); `onRemoved(monster)` when one loses it.
function Context:onBossEvent(eventName, onAdded, onRemoved)
	local wanted = eventName:lower()
	local function ours(creature, name)
		return type(name) == "string" and name:lower() == wanted and creature:isMonster() and creature:getInstanceId() == self.instanceId
	end
	local function added(monsterId)
		self:after(0, function()
			local monster = Monster(monsterId)
			if monster and ExpeditionBossMechanics.hasEvent(monster, eventName) then
				onAdded(monster)
			end
		end)
	end
	self:on("creature.eventRegistered", function(creature, name)
		if ours(creature, name) then
			added(creature:getId())
		end
	end)
	self:on("boss.bound", function(session, monster)
		if session == self.session then
			added(monster:getId())
		end
	end)
	if onRemoved then
		self:on("creature.eventUnregistered", function(creature, name)
			if ours(creature, name) then
				onRemoved(creature)
			end
		end)
	end
	local boss = self:boss()
	if boss then
		added(boss:getId())
	end
end

--- While a boss of the fight has creature event `eventName`: `fn(boss)` now and every
--- `intervalMs` (for answers that may need repeating).
function Context:whileBossHasEvent(eventName, intervalMs, fn)
	local loop = "while:" .. eventName
	local bossId = nil
	local function step()
		local boss = bossId and Monster(bossId)
		if boss and ExpeditionBossMechanics.hasEvent(boss, eventName) then
			fn(boss)
		else
			self.scope:cancel(loop)
		end
	end
	self:onBossEvent(eventName, function(boss)
		if bossId == boss:getId() and self.scope:pending(loop) then
			return
		end
		bossId = boss:getId()
		self:every(intervalMs, step, loop)
		step()
	end, function(boss)
		if boss:getId() == bossId then
			self.scope:cancel(loop)
		end
	end)
end

--- `fn(item)` for every item of `itemIds` the fight's encounter script creates.
function Context:onItemCreated(itemIds, fn)
	if not self.copy then
		return
	end
	local wanted = {}
	for _, id in ipairs(itemIds) do
		wanted[id] = true
	end
	EncounterInstances.watchItems(self.copy, function(item)
		if wanted[item:getId()] and self:live() then
			self.scope:run(fn, item)
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
-- over by hand; keepGoing / waitUntil / onDone run in the instance.

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
		if not keepGoing then
			return true
		end
		local ok, keep = self.scope:run(keepGoing, player)
		return ok and keep
	end
	if waitUntil then
		wrapped.waitUntil = function(player)
			local ok, ready = self.scope:run(waitUntil, player)
			return ok and ready
		end
	end
	wrapped.onDone = onDone and function(player, ok, reason)
		if self:live() then
			self.scope:run(onDone, player, ok, reason)
		end
	end or nil
	return wrapped
end

function Context:playerController(player)
	if not player or not PlayerController then
		return nil
	end
	local ctrl = PlayerController.get(player)
	ctrl:bindManualMap(self.session and self.session.manualIds)
	return ctrl
end

function Context:walkTo(player, dest, opts)
	local ctrl = self:playerController(player)
	if ctrl then
		local wrapped = self:errandOpts(opts)
		wrapped.noTeleport = true -- stay in the arena; never warp mid-mechanic
		return ctrl:goTo(dest, wrapped)
	end
	return PlayerErrand.walkTo(player, dest, self:errandOpts(opts))
end

function Context:stepOnto(player, dest, opts)
	local ctrl = self:playerController(player)
	if ctrl then
		return ctrl:stepOnto(dest, self:errandOpts(opts))
	end
	return PlayerErrand.stepOnto(player, dest, self:errandOpts(opts))
end

function Context:use(player, position, itemId, opts)
	local ctrl = self:playerController(player)
	if ctrl then
		return ctrl:useAt(position, itemId, self:errandOpts(opts))
	end
	return PlayerErrand.use(player, position, itemId, self:errandOpts(opts))
end

function Context:useWith(player, itemId, position, opts)
	local ctrl = self:playerController(player)
	if ctrl then
		return ctrl:useWith(itemId, position, self:errandOpts(opts))
	end
	return PlayerErrand.useWith(player, itemId, position, self:errandOpts(opts))
end

function Context:pickUp(player, position, itemId, opts)
	local ctrl = self:playerController(player)
	if ctrl then
		return ctrl:pickUp(position, itemId, self:errandOpts(opts))
	end
	return PlayerErrand.pickUp(player, position, itemId, self:errandOpts(opts))
end

--- Run `job(player, done)` for `player` after its earlier jobs, in order (never before the
--- next tick, and only while the AI drives the player: paused or under manual control, its
--- jobs wait for the tick that finds it driven again); the job calls `done()` once finished
--- (typically from an errand's onDone). `onDrop()` runs instead of the job when it is
--- dropped unrun (the player logged out).
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
		elseif self.jobs[id] == jobs then
			self.jobs[id] = nil
		end
	end
	if not player then
		if job.drop then
			IdleSafe.call("BossMechanics.drop." .. tostring(id), job.drop)
		end
		return done()
	end
	local ok, err = pcall(job.run, player, done)
	if not ok then
		logger.error("[ExpeditionBossMechanics] {}: job failed: {}", self.name, tostring(err))
		done()
	end
end

--- Standing goal: `fn()` now and on every mechanic tick.
function Context:goal(fn)
	self.goals[#self.goals + 1] = fn
	fn()
end

function Context:tick()
	for _, goal in ipairs(self.goals) do
		local ok, err = pcall(goal)
		if not ok then
			logger.error("[ExpeditionBossMechanics] {}: goal failed: {}", self.name, tostring(err))
		end
	end
	local waiting = {}
	for id in pairs(self.jobs) do
		waiting[#waiting + 1] = id
	end
	for _, id in ipairs(waiting) do
		self:runJob(id)
	end
end

--- While `active()` holds, every agent keeps `job(player, done)` going: it is queued again
--- each time the previous run finished, so members taken over by hand (or paused) pick
--- their duty back up once the AI drives them again.
function Context:duty(active, job)
	local busy = {}
	self:goal(function()
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
	self:goal(function()
		local live, session = self:live()
		if not live then
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

--- Once the encounter enters `stage` (or right away when it is there), wait `delayMs` and run `fn`.
function Context:onStage(stage, delayMs, fn)
	if not self.copy then
		return
	end
	local unsubscribe, fired = nil, false
	local function fire()
		if fired then
			return
		end
		fired = true
		if unsubscribe then
			unsubscribe()
		end
		self:after(delayMs, fn)
	end
	unsubscribe = self:on("encounter.stage", function(encounter, stageNumber)
		if encounter == self.copy.encounter and stageNumber == stage then
			fire()
		end
	end)
	if self:stage() == stage then
		fire()
	end
end

--- Every agent on its floor opens each chest of `itemIds` the stock script places (stage
--- rewards) once, before its next move; members taken over by hand open it once the AI
--- drives them again.
function Context:rewardChests(itemIds)
	local chests = {}
	local function openChests()
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
	self:onItemCreated(itemIds, function(item)
		chests[#chests + 1] = { itemId = item:getId(), position = item:getPosition(), opened = {}, queued = {} }
		openChests()
	end)
	self:goal(openChests)
end

--- `mechanic(ctx)` plays boss `name`'s mechanic (boss name, or encounter name for
--- encounter-run fights) in expeditions. `opts.immunity`: creature events that make the boss
--- immune until the mechanic is played (kept on the boss; stripped only when it stalls).
function ExpeditionBossMechanics.register(name, mechanic, opts)
	local immunity = opts and opts.immunity or {}
	ExpeditionBossMechanics.mechanics[name:lower()] = { name = name, run = mechanic, immunity = immunity }
	for _, eventName in ipairs(immunity) do
		immunityEvents[eventName:lower()] = true
	end
end

--- True when a registered mechanic declares creature event `name` as its boss's immunity.
function ExpeditionBossMechanics.isImmunityEvent(name)
	return type(name) == "string" and immunityEvents[name:lower()] == true
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
		session = session,
		instanceId = session.instance.instanceId,
		lever = lever,
		copy = copy,
		jobs = {},
		running = {},
		goals = {},
	}, Context)
	ctx.scope = ExpeditionManager.scope(session):child({
		name = "mechanic:" .. mechanic.name,
		alive = function()
			return session.bossMechanic == ctx and session.state == "hunting" and (not copy or copy.alive)
		end,
	})
	session.bossMechanic = ctx
	local ok = ctx.scope:run(mechanic.run, ctx)
	ctx:every(TICK_MS, function()
		ctx:tick()
	end)
	ctx:on("member.resumed", function(run)
		if run == session then
			ctx:tick()
		end
	end)
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
	ctx.scope:dispose()
end
