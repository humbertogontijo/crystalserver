local base = DATA_DIRECTORY .. "/lib/custom/activity_boost/"
local files = {
	"01_config.lua",
	"02_ledger.lua",
	"03_activities.lua",
	"05_solo_boss.lua",
	"06_world_boss.lua",
	"07_protocol.lua",
}

for _, file in ipairs(files) do
	dofile(base .. file)
end
