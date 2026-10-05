-- Lobbies: Grand Chase-style rooms (members, settings, bonuses, private room, start flow).
local base = DATA_DIRECTORY .. "/lib/idleot/lobby/"
local files = {
	"01_config.lua",
	"02_store.lua",
	"03_bonus.lua",
	"04_instance.lua",
	"05_services.lua",
	"06_manager.lua",
	"07_travel.lua",
	"08_protocol.lua",
	"09_start.lua",
}

for _, file in ipairs(files) do
	dofile(base .. file)
end
