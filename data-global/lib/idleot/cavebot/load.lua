-- Ordered cavebot library loader (not under scripts/, so not auto-scanned).
-- Cave walker shared by expedition hunts and open-world runs.
local base = DATA_DIRECTORY .. "/lib/idleot/cavebot/"
local files = {
	"01_config.lua",
	"02_run.lua",
	"03_core.lua",
	"04_pack.lua",
	"05_directives.lua",
	"06_store.lua",
	"07_protocol.lua",
	"08_routes.lua",
	"09_service.lua",
}

for _, file in ipairs(files) do
	dofile(base .. file)
end
