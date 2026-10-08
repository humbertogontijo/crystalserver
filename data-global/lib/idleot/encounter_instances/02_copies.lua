-- Per-instance copies of stock encounter scripts: the sandbox a copy runs in (its
-- revscript objects only capture callbacks) and EncounterInstances.start / stop.
-- Routing world-run callbacks to the copies: 01_routing.lua.

local state = EncounterInstances.state
local ROUTED_METHODS = EncounterInstances.ROUTED_METHODS

local function noop(self)
	return self
end

local function notifySpawn(copy, monster)
	if monster and copy.alive and copy.onSpawn then
		local ok, err = pcall(copy.onSpawn, monster)
		if not ok then
			logger.error("[EncounterInstances] spawn hook for {} failed: {}", copy.name, tostring(err))
		end
	end
end

local function notifyItem(copy, item)
	if not item or not copy.alive or type(item) ~= "userdata" then
		return
	end
	for _, watcher in ipairs(copy.itemWatchers) do
		local ok, err = pcall(watcher, item)
		if not ok then
			logger.error("[EncounterInstances] item watcher for {} failed: {}", copy.name, tostring(err))
		end
	end
end

--- Revscript object of the copy: `on*` callbacks are captured (in registration order, per
--- class.method) and every other call is a no-op, so nothing registers with the engine.
local function callbackStub(copy, className)
	local function record(key, callback)
		if type(callback) ~= "function" then
			return
		end
		local fullKey = className .. "." .. key
		copy.callbacks[fullKey] = copy.callbacks[fullKey] or {}
		table.insert(copy.callbacks[fullKey], callback)
	end
	return setmetatable({}, {
		__index = function(_, key)
			if type(key) == "string" and key:find("^on%u") then
				return function(self, callback)
					record(key, callback)
					return self
				end
			end
			return noop
		end,
		__newindex = function(self, key, value)
			if type(key) == "string" and key:find("^on%u") then
				record(key, value)
				return
			end
			rawset(self, key, value)
		end,
	})
end

--- GlobalEvent of the copy: its onThink runs on the instance's own timer.
local function globalEventStub(copy)
	local event = { interval = 0 }
	local function start()
		local onThink, interval = event.onThink, event.interval
		if type(onThink) ~= "function" or interval <= 0 then
			return
		end
		copy.scope:every(interval, function()
			onThink(interval, os.time())
		end)
	end
	return setmetatable({}, {
		__index = function(_, key)
			if key == "interval" then
				return function(self, ms)
					event.interval = tonumber(ms) or 0
					return self
				end
			elseif key == "register" then
				return function()
					start()
					return true
				end
			end
			return noop
		end,
		__newindex = function(self, key, value)
			if key == "onThink" then
				event.onThink = value
				return
			end
			if type(key) == "string" and key:find("^on%u") then
				return
			end
			rawset(self, key, value)
		end,
	})
end

--- Registrations the copy drops (zone/global callbacks keep running from the world run).
local function inertStub()
	return setmetatable({}, {
		__index = function()
			return noop
		end,
		__newindex = function() end,
	})
end

local function encounterClass(copy)
	local class = setmetatable({}, { __index = Encounter })
	function class:register()
		self.registered = true
		return true
	end
	-- The copy is started by its owner, not by players entering the shared zone.
	function class:startOnEnter() end
	function class:spawnMonsters(config)
		local spawn = config.spawn
		local wrapped = {}
		for k, v in pairs(config) do
			wrapped[k] = v
		end
		wrapped.spawn = function(monster)
			notifySpawn(copy, monster)
			if spawn then
				return spawn(monster)
			end
		end
		return Encounter.spawnMonsters(self, wrapped)
	end
	return setmetatable({}, {
		__index = Encounter,
		__call = function(_, name, config)
			if not name then
				error("Encounter: name is required")
			end
			local encounter = copy.encounters[name]
			if not encounter then
				encounter = setmetatable({ name = name }, { __index = class })
				copy.encounters[name] = encounter
			end
			if config then
				encounter:resetConfig(config)
			end
			return encounter
		end,
	})
end

local function buildEnv(copy)
	local env = setmetatable({}, { __index = _G })
	local function constructor(make)
		return setmetatable({}, {
			__call = function(_, ...)
				return make(...)
			end,
		})
	end
	env.Encounter = encounterClass(copy)
	for className in pairs(ROUTED_METHODS) do
		env[className] = constructor(function()
			return callbackStub(copy, className)
		end)
	end
	env.GlobalEvent = constructor(function()
		return globalEventStub(copy)
	end)
	env.EventCallback = constructor(inertStub)
	env.ZoneEvent = constructor(inertStub)
	-- A halted copy may keep routing callbacks (opts.keepCallbacks); their timers still run.
	env.addEvent = function(callback, delay, ...)
		if copy.alive then
			return copy.scope:addEvent(callback, delay, ...)
		end
		return addEvent(callback, delay, ...)
	end
	env.Game = setmetatable({
		createMonster = function(...)
			local monster = Game.createMonster(...)
			notifySpawn(copy, monster)
			return monster
		end,
		createItem = function(...)
			local item = Game.createItem(...)
			notifyItem(copy, item)
			return item
		end,
	}, { __index = Game })
	return env
end

local function halt(copy)
	if not copy.alive then
		return
	end
	copy.alive = false
	for _, encounter in pairs(copy.encounters) do
		IdleSafe.call("EncounterInstances.halt", encounter.cancelEvents, encounter)
	end
	copy.scope:dispose()
end

--- True when a scripts/ file builds encounter `name` (an instance copy can be started).
function EncounterInstances.has(name)
	return type(name) == "string" and state.fileByEncounter[name] ~= nil
end

--- Live copy of encounter `name` in `instanceId`.
function EncounterInstances.get(instanceId, name)
	local path = state.fileByEncounter[name]
	local copies = path and state.copies[path]
	local copy = copies and copies[Instance.normalize(instanceId)]
	return copy and copy.alive and copy or nil
end

--- Re-run the script that builds encounter `name` as a copy owned by private instance
--- `instanceId` and start its encounter there. opts.onSpawn(monster): every monster the
--- copy creates; opts.scope: owner Scope (the copy's timers end with it). Returns the
--- copy, or nil and a reason.
function EncounterInstances.start(name, instanceId, opts)
	opts = opts or {}
	instanceId = Instance.normalize(instanceId)
	if not instanceId or not Instance.isPrivate(instanceId) then
		return nil, "not a private instance"
	end
	local path = state.fileByEncounter[name]
	if not path then
		return nil, "no script builds encounter " .. tostring(name)
	end
	local chunk, loadErr = loadfile(path)
	if not chunk then
		return nil, tostring(loadErr)
	end
	EncounterInstances.stop(instanceId, name)

	local copy = {
		name = name,
		path = path,
		instanceId = instanceId,
		alive = true,
		onSpawn = opts.onSpawn,
		itemWatchers = {},
		callbacks = {},
		encounters = {},
	}
	local scopeOpts = {
		name = "encounter:" .. name,
		instanceId = instanceId,
		alive = function()
			return copy.alive
		end,
	}
	copy.scope = opts.scope and opts.scope:child(scopeOpts) or Scope.new(scopeOpts)
	setfenv(chunk, buildEnv(copy))
	local ran, ok, runErr = pcall(Game.runInInstance, instanceId, function()
		return pcall(chunk)
	end)
	local encounter = copy.encounters[name]
	if not ran or not ok or not encounter then
		halt(copy)
		return nil, tostring(runErr or ok or "encounter not built")
	end
	copy.encounter = encounter
	state.copies[path] = state.copies[path] or {}
	state.copies[path][instanceId] = copy

	Game.runInInstance(instanceId, function()
		encounter:reset()
		encounter:start()
	end)
	return copy
end

--- Stop the copies living in `instanceId` (all, or the one building `name`): timers,
--- loops and encounter events. opts.keepCallbacks keeps routing the instance's creatures
--- to the halted copy (e.g. reward chests while the party loots).
function EncounterInstances.stop(instanceId, name, opts)
	instanceId = Instance.normalize(instanceId)
	if not instanceId then
		return
	end
	local only = name and state.fileByEncounter[name] or nil
	for path, copies in pairs(state.copies) do
		local copy = copies[instanceId]
		if copy and (not only or only == path) then
			halt(copy)
			if not (opts and opts.keepCallbacks) then
				copies[instanceId] = nil
			end
		end
	end
end

--- `watcher(item)` for every item the copy's script creates (Game.createItem).
function EncounterInstances.watchItems(copy, watcher)
	table.insert(copy.itemWatchers, watcher)
end
