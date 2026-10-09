-- Stock behaviour the product listens to, published on IdleEvents: encounter stage changes
-- (the Encounter.onEnterStage slot in data/libs/systems/encounters.lua). Creature event
-- (un)registration and instance release come from engine callbacks in scripts/idleot/core.
--
-- Product libs load after data/libs, which recreates Encounter on every core reload, so the
-- slot is assigned here on every load.

function Encounter.onEnterStage(encounter, stageNumber)
	IdleEvents.emit("encounter.stage", encounter, stageNumber)
end
