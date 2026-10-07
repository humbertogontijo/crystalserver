local base = DATA_DIRECTORY .. "/lib/idleot/store/"
local files = {
	"01_config.lua",
	"02_offers.lua",
}

for _, file in ipairs(files) do
	dofile(base .. file)
end
