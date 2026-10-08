-- Stock behaviour the product listens to, published on IdleEvents without editing stock
-- files: encounter stage changes, creature event (un)registration (boss immunity scripts
-- toggle these) and instance release (engine callback, see scripts/idleot/core).
--
-- Encounter lives in data/libs, which loads after the product libs, so install() runs from
-- scripts/idleot/core/events.lua.

IdleHooks = IdleHooks or {}

local function installEncounter()
	local enterStage = Encounter.enterStage
	function Encounter:enterStage(stageNumber, abort)
		local ok = enterStage(self, stageNumber, abort)
		if ok then
			IdleEvents.emit("encounter.stage", self, stageNumber)
		end
		return ok
	end
end

local function installCreatureEvents()
	local register, unregister = Creature.registerEvent, Creature.unregisterEvent
	function Creature:registerEvent(name)
		local ok = register(self, name)
		if ok and IdleEvents.has("creature.eventRegistered") then
			IdleEvents.emit("creature.eventRegistered", self, name)
		end
		return ok
	end
	function Creature:unregisterEvent(name)
		local ok = unregister(self, name)
		if ok and IdleEvents.has("creature.eventUnregistered") then
			IdleEvents.emit("creature.eventUnregistered", self, name)
		end
		return ok
	end
end

function IdleHooks.install()
	if IdleHooks.installed then
		return
	end
	IdleHooks.installed = true
	installEncounter()
	installCreatureEvents()
end
