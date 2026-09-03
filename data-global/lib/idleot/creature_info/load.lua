local base = DATA_DIRECTORY .. "/lib/idleot/creature_info/"
local files = {
	"01_load.lua",
	"02_levels.lua",
	"03_pack.lua",
}

for _, file in ipairs(files) do
	dofile(base .. file)
end
