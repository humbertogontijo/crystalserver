-- Stock behaviour the product listens to, published on IdleEvents without editing stock
-- files: encounter stage changes, creature event (un)registration (boss immunity scripts
-- toggle these) and instance release (engine callback, see scripts/idleot/core).
--
-- Product libs load after data/libs, which recreates Encounter on every core reload; the
-- Creature methods are engine bindings, so their originals are kept across reloads.

IdleHooks = IdleHooks or {}

local enterStage = Encounter.enterStage
function Encounter:enterStage(stageNumber, abort)
	local ok = enterStage(self, stageNumber, abort)
	if ok then
		IdleEvents.emit("encounter.stage", self, stageNumber)
	end
	return ok
end

IdleHooks.registerEvent = IdleHooks.registerEvent or Creature.registerEvent
IdleHooks.unregisterEvent = IdleHooks.unregisterEvent or Creature.unregisterEvent
local register, unregister = IdleHooks.registerEvent, IdleHooks.unregisterEvent

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
