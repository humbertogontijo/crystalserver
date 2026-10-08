-- Scope: timers and event subscriptions that belong to one owner (an expedition session,
-- a boss mechanic, an encounter copy, a cavebot run) and end together with it.
--
--   local scope = Scope.new({ name = "...", instanceId = key, alive = function() ... end })
--   scope:after(ms, fn)          once, later
--   scope:every(ms, fn, name?)   repeatedly (first run after ms)
--   scope:sweep(ms, fn)          now and repeatedly
--   scope:timer(name, ms, fn)    once, replacing an earlier timer of that name
--   scope:addEvent(fn, ms, ...)  addEvent-compatible (returns the raw event id)
--   scope:on(event, fn)          IdleEvents subscription
--   scope:child(opts)            nested scope, disposed with this one
--   scope:onDispose(fn)          cleanup hook
--   scope:dispose()
--
-- Callbacks run only while the scope is alive (not disposed, its `alive` predicate holds
-- and its parent is alive), inside its instance (Game.runInInstance) when it has one, and
-- under pcall. A dead scope's timers simply stop; dispose cancels them right away.
-- `instanceId` may be a function (resolved per run); children without one use the parent's.

Scope = Scope or {}
Scope.__index = Scope

function Scope.new(opts)
	opts = opts or {}
	return setmetatable({
		name = opts.name or "scope",
		instanceId = opts.instanceId,
		isAlive = opts.alive,
		parent = opts.parent,
		timers = {}, -- handle -> true
		named = {}, -- timer name -> handle
		unsubscribers = {},
		children = {},
		disposers = {},
	}, Scope)
end

function Scope:alive()
	if self.disposed then
		return false
	end
	if self.parent and not self.parent:alive() then
		return false
	end
	return not self.isAlive or self.isAlive() == true
end

--- Instance the scope's callbacks run in (nil: the caller's).
function Scope:instance()
	local id = self.instanceId
	if type(id) == "function" then
		id = id()
	end
	if id == nil and self.parent then
		return self.parent:instance()
	end
	return id
end

--- `fn(...)` now, in the scope's instance, under pcall. Returns ok, results.
function Scope:run(fn, ...)
	local ok, a, b, c
	local instanceId = self:instance()
	if instanceId then
		ok, a, b, c = pcall(Game.runInInstance, instanceId, fn, ...)
	else
		ok, a, b, c = pcall(fn, ...)
	end
	if not ok then
		logger.error("[Scope] {}: {}", self.name, tostring(a))
		return false
	end
	return true, a, b, c
end

local function schedule(self, handle, ms, fn)
	handle.id = addEvent(function()
		handle.id = nil
		if not self.timers[handle] then
			return
		end
		if not handle.repeating then
			self.timers[handle] = nil
		end
		if self:alive() then
			self:run(fn)
			if handle.repeating and self.timers[handle] then
				schedule(self, handle, ms, fn)
			end
		else
			self.timers[handle] = nil
		end
	end, math.max(0, ms or 0))
end

--- `fn()` once after `ms`. Returns a handle for `cancel`.
function Scope:after(ms, fn)
	if self.disposed then
		return nil
	end
	local handle = {}
	self.timers[handle] = true
	schedule(self, handle, ms, fn)
	return handle
end

--- `fn()` every `ms` (first run after `ms`) until cancelled or the scope ends. A `name`
--- replaces the earlier loop of that name (cancel/pending accept it too).
function Scope:every(ms, fn, name)
	if self.disposed then
		return nil
	end
	if name then
		self:cancel(name)
	end
	local handle = { repeating = true }
	self.timers[handle] = true
	schedule(self, handle, ms, fn)
	if name then
		self.named[name] = handle
	end
	return handle
end

--- `fn()` now and every `ms` after.
function Scope:sweep(ms, fn)
	local handle = self:every(ms, fn)
	if handle and self:alive() then
		self:run(fn)
	end
	return handle
end

--- `fn()` once after `ms`, replacing the pending timer called `name` (if any).
function Scope:timer(name, ms, fn)
	self:cancel(name)
	local handle
	handle = self:after(ms, function()
		if self.named[name] == handle then
			self.named[name] = nil
		end
		fn()
	end)
	self.named[name] = handle
	return handle
end

--- Drop-in `addEvent(fn, ms, ...)` for code that keeps raw ids (and may stopEvent them).
function Scope:addEvent(fn, ms, ...)
	if self.disposed then
		return nil
	end
	local handle = {}
	self.timers[handle] = true
	handle.id = addEvent(function(...)
		handle.id = nil
		if self.timers[handle] then
			self.timers[handle] = nil
			if self:alive() then
				self:run(fn, ...)
			end
		end
	end, math.max(0, ms or 0), ...)
	return handle.id
end

--- True while the timer `name` is pending.
function Scope:pending(name)
	local handle = self.named[name]
	return handle ~= nil and self.timers[handle] == true
end

--- Cancel a timer by handle or by name.
function Scope:cancel(handleOrName)
	local handle = handleOrName
	if type(handleOrName) == "string" then
		handle = self.named[handleOrName]
		self.named[handleOrName] = nil
	end
	if not handle or not self.timers[handle] then
		return
	end
	self.timers[handle] = nil
	if handle.id then
		stopEvent(handle.id)
		handle.id = nil
	end
end

--- Subscribe to IdleEvents `event` for the scope's lifetime; `fn` runs only while alive.
function Scope:on(event, fn)
	if self.disposed then
		return nil
	end
	local unsubscribe = IdleEvents.on(event, function(...)
		if self:alive() then
			self:run(fn, ...)
		end
	end)
	self.unsubscribers[#self.unsubscribers + 1] = unsubscribe
	return unsubscribe
end

--- Nested scope (same instance unless `opts.instanceId`), disposed with this one.
function Scope:child(opts)
	opts = opts or {}
	local child = Scope.new({
		name = opts.name or self.name,
		instanceId = opts.instanceId,
		alive = opts.alive,
		parent = self,
	})
	self.children[#self.children + 1] = child
	return child
end

function Scope:onDispose(fn)
	self.disposers[#self.disposers + 1] = fn
end

function Scope:dispose()
	if self.disposed then
		return
	end
	self.disposed = true
	local children = self.children
	self.children = {}
	for _, child in ipairs(children) do
		child:dispose()
	end
	local siblings = self.parent and self.parent.children
	for i, sibling in ipairs(siblings or {}) do
		if sibling == self then
			table.remove(siblings, i)
			break
		end
	end
	for handle in pairs(self.timers) do
		if handle.id then
			stopEvent(handle.id)
			handle.id = nil
		end
	end
	for _, unsubscribe in ipairs(self.unsubscribers) do
		unsubscribe()
	end
	for _, fn in ipairs(self.disposers) do
		local ok, err = pcall(fn)
		if not ok then
			logger.error("[Scope] {} dispose hook failed: {}", self.name, tostring(err))
		end
	end
	self.timers, self.named, self.unsubscribers, self.disposers = {}, {}, {}, {}
end
