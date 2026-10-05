-- Account alts: companions, headless deploy and alt switching (no team/lobby notion).
local base = DATA_DIRECTORY .. "/lib/idleot/alts/"
local files = {
	"01_config.lua",
	"02_resolve.lua",
	"03_companions.lua",
	"04_switch.lua",
	"05_client.lua",
}

for _, file in ipairs(files) do
	dofile(base .. file)
end
