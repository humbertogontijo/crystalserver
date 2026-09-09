-- Ordered expedition library loader (not under scripts/, so not auto-scanned).
local base = DATA_DIRECTORY .. "/lib/idleot/expeditions/"
local files = {
	"01_json.lua",
	"02_config.lua",
	"02a_creature_info.lua",
	"03_instance.lua",
	"04_waves.lua",
	"04b_boss.lua",
	"04c_boss_detail.lua",
	"05_ai.lua",
	"06_protocol.lua",
	"07_manager.lua",
	"08_sample_spells.lua",
	"09_raid_instance.lua",
	"10_xml_raids.lua",
	"11_persist.lua",
	"12_safety.lua",
	"13_difficulty.lua",
}

for _, file in ipairs(files) do
	dofile(base .. file)
end
