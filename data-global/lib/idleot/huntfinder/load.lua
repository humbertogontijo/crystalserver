local base = DATA_DIRECTORY .. "/lib/idleot/huntfinder/"
local files = {
	"01_config.lua",
	"02_protocol.lua",
}

for _, file in ipairs(files) do
	dofile(base .. file)
end
