-- Ordered combat automation library loader (not under scripts/, so not auto-scanned).
local base = DATA_DIRECTORY .. "/lib/idleot/combat_automation/"
local files = {
	"01_anchor_spot.lua",
	"02_cave_route.lua",
	"03_config.lua",
	"04_base_loadouts.lua",
	"05_catalog.lua",
	"06_walk.lua",
	"07_danger.lua",
	"08_halt_spot.lua",
	"09_formation.lua",
	"10_movement.lua",
	"11_errand.lua",
	"12_runtime.lua",
	"13_store.lua",
	"14_protocol.lua",
}

for _, file in ipairs(files) do
	dofile(base .. file)
end
