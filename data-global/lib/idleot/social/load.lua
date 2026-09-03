-- Social friends + team listings library loader.
local base = DATA_DIRECTORY .. "/lib/idleot/social/"
local files = {
	"01_json.lua",
	"02_config.lua",
	"03_friends_store.lua",
	"04_listings_store.lua",
	"05_protocol.lua",
}

for _, file in ipairs(files) do
	dofile(base .. file)
end
