-- Ordered cavebot library loader (not under scripts/, so not auto-scanned).
-- Cave walker shared by expedition hunts and open-world runs.
local base = DATA_DIRECTORY .. "/lib/idleot/cavebot/"
local files = {
	"01_config.lua",
	"02_run.lua",
	"03a_state.lua",
	"03b_halt.lua",
	"03c_walk.lua",
	"03d_tick.lua",
	"03e_anchor_directive.lua",
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
