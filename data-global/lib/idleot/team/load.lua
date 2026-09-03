-- account team library loader (not under scripts/, so not auto-scanned).
local base = DATA_DIRECTORY .. "/lib/idleot/team/"
local files = {
	"01_json.lua",
	"02_config.lua",
	"03_store.lua",
	"04_protocol.lua",
	"05_manager.lua",
	"06_bonus.lua",
}

for _, file in ipairs(files) do
	dofile(base .. file)
end
