local base = DATA_DIRECTORY .. "/lib/idleot/expeditions/boss_mechanics/"
local files = {
	"00_core.lua",
	"faceless_bane.lua",
	"grand_master_oberon.lua",
	"timira_the_many_headed.lua",
}

for _, file in ipairs(files) do
	dofile(base .. file)
end
