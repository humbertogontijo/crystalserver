local base = DATA_DIRECTORY .. "/lib/idleot/activity_boost/"
local files = {
	"01_config.lua",
	"02_ledger.lua",
	"03_activities.lua",
	"06_world_boss.lua",
	"08_fiendish_hunt.lua",
	"07_protocol.lua",
}

for _, file in ipairs(files) do
	dofile(base .. file)
end
