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
-- through, and only touches Encounter once scripts load. The copies themselves (sandbox
-- and start / stop): 02_copies.lua.

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

--- Revscript classes whose callbacks route to instance copies (02_copies stubs them).
EncounterInstances.ROUTED_METHODS = {
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

for className, methods in pairs(EncounterInstances.ROUTED_METHODS) do
	for _, method in ipairs(methods) do
		wrapMethod(className, method)
	end
end
