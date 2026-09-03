-- Ordered combat automation library loader (not under scripts/, so not auto-scanned).
local base = DATA_DIRECTORY .. "/lib/idleot/combat_automation/"
local files = {
	"01_json.lua",
	"01_config.lua",
	"01_base_loadouts.lua",
	"02_catalog.lua",
	"03_runtime.lua",
	"04_store.lua",
	"05_protocol.lua",
}

for _, file in ipairs(files) do
	dofile(base .. file)
end
