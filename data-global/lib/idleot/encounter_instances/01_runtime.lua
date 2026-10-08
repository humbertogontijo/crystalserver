-- Per-instance copies of stock encounter scripts.
--
-- A script under scripts/ that builds an Encounter keeps module state (stage, puzzle
-- points, ...) in file locals and its Encounter is a global singleton, so one world run
-- serves the whole server. Private instances (expeditions) get their own copy of such a
-- file: it is re-run from disk with its own globals table, its Encounter/GlobalEvent/
-- callback objects are captured instead of registered, and every creature-driven callback
-- the world run registered routes to the copy of the creature's instance. The world run
-- (open world, other instances) is untouched, so the stock scripts need no changes.
--
-- Load order: this file runs before data/libs (revscriptsys, encounters, zones), so it
-- wraps the C++ class methods (Action.onUse, ...) every revscript registration goes
-- through, and only touches Encounter once scripts load.

EncounterInstances = EncounterInstances or {}

local state = EncounterInstances.state
	or {
		-- encounter name -> script path that builds it
		fileByEncounter = {},
		-- script path -> encounter names it builds (false: not an encounter script)
		encounterNamesByFile = {},
		-- script path -> { chunk, counters } of the world run (ordinals per callback key)
		worldRuns = {},
		-- script path -> instanceId -> copy
		copies = {},
		-- class.method -> original C++ method
		originals = {},
	}
EncounterInstances.state = state

local ROUTED_METHODS = {
	Action = { "onUse" },
	MoveEvent = { "onStepIn", "onStepOut", "onAddItem", "onRemoveItem", "onEquip", "onDeEquip" },
	CreatureEvent = {
		"onLogin",
		"onLogout",
		"onThink",
		"onPrepareDeath",
		"onDeath",
		"onKill",
		"onAdvance",
		"onModalWindow",
		"onTextEdit",
		"onHealthChange",
		"onManaChange",
		"onExtendedOpcode",
	},
	TalkAction = { "onSay" },
}

local function noop(self)
	return self
end

--- Script file and main chunk of the scripts/ file currently registering (nil outside one).
local function loadingScript()
	for level = 3, 16 do
		local info = debug.getinfo(level, "Sf")
		if not info then
			return nil
		end
		local source = info.source
		if info.what == "main" and type(source) == "string" and source:sub(1, 1) == "@" then
			local path = source:sub(2)
			if path:find("/scripts/", 1, true) then
				return path, info.func
			end
		end
	end
	return nil
end

--- Encounter names a script builds (`Encounter("Name", config)`), false when it touches none.
local function encounterNames(path)
	local cached = state.encounterNamesByFile[path]
	if cached ~= nil then
		return cached
	end
	local names = false
	local file = io.open(path, "r")
	if file then
		local text = file:read("*a") or ""
		file:close()
		if text:find("%f[%w_]Encounter%(") then
			names = {}
			for name in text:gmatch("%f[%w_]Encounter%(%s*[\"']([^\"']+)[\"']%s*,") do
				names[#names + 1] = name
				state.fileByEncounter[name] = state.fileByEncounter[name] or path
			end
		end
	end
	state.encounterNamesByFile[path] = names
	return names
end

local function instanceOf(thing)
	if type(thing) == "userdata" and thing.getInstanceId then
		return thing:getInstanceId()
	end
	return nil
end

--- World callback that runs the instance copy's matching callback for creatures/items in a
--- copied instance. Copies register callbacks in the same order as the world run, so
--- (key, ordinal) names the same callback in both.
local function route(path, chunk, key, worldCallback)
	local run = state.worldRuns[path]
	if not run or run.chunk ~= chunk then
		run = { chunk = chunk, counters = {} }
		state.worldRuns[path] = run
	end
	local ordinal = (run.counters[key] or 0) + 1
	run.counters[key] = ordinal
	return function(first, second, ...)
		local copies = state.copies[path]
		if copies then
			local copy = copies[instanceOf(first) or instanceOf(second)]
			if copy then
				local list = copy.callbacks[key]
				local callback = list and list[ordinal]
				if callback then
					return callback(first, second, ...)
				end
			end
		end
		return worldCallback(first, second, ...)
	end
end

--- The script registering an encounter owns it (also covers non-literal names).
local function hookEncounterRegister()
	if state.registerHooked or type(Encounter) ~= "table" or type(Encounter.register) ~= "function" then
		return
	end
	state.registerHooked = true
	local register = Encounter.register
	Encounter.register = function(self, ...)
		local path = loadingScript()
		if path and self and self.name then
			state.fileByEncounter[self.name] = path
		end
		return register(self, ...)
	end
end

local function wrapMethod(className, method)
	local class = rawget(_G, className)
	local key = className .. "." .. method
	local original = state.originals[key] or (class and rawget(class, method))
	if type(original) ~= "function" then
		return
	end
	state.originals[key] = original
	class[method] = function(self, callback, ...)
		hookEncounterRegister()
		if type(callback) == "function" then
			local path, chunk = loadingScript()
			if path and encounterNames(path) then
				callback = route(path, chunk, key, callback)
			end
		end
		return original(self, callback, ...)
	end
end

for className, methods in pairs(ROUTED_METHODS) do
	for _, method in ipairs(methods) do
		wrapMethod(className, method)
	end
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

local function trackEvent(copy, eventId)
	if eventId then
		copy.events[#copy.events + 1] = eventId
	end
	return eventId
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
		local function tick()
			if not copy.alive then
				return
			end
			local ok, err = pcall(onThink, interval, os.time())
			if not ok then
				logger.error("[EncounterInstances] {} onThink in {} failed: {}", copy.name, copy.instanceId, tostring(err))
			end
			copy.loops[event] = addEvent(tick, interval)
		end
		copy.loops[event] = addEvent(tick, interval)
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
	env.addEvent = function(...)
		return trackEvent(copy, addEvent(...))
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
		pcall(encounter.cancelEvents, encounter)
	end
	for _, eventId in pairs(copy.loops) do
		stopEvent(eventId)
	end
	for _, eventId in ipairs(copy.events) do
		stopEvent(eventId)
	end
	copy.loops, copy.events = {}, {}
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
--- copy creates. Returns the copy, or nil and a reason.
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
		loops = {},
		events = {},
	}
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

--- addEvent owned by the copy: cancelled when the copy stops, skipped once it halted.
function EncounterInstances.addEvent(copy, callback, delay, ...)
	return trackEvent(
		copy,
		addEvent(function(...)
			if copy.alive then
				callback(...)
			end
		end, delay, ...)
	)
end
