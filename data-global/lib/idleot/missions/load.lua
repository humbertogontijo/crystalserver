local base = DATA_DIRECTORY .. "/lib/idleot/missions/"
dofile(base .. "01_config.lua")
dofile(base .. "02_runtime.lua")
dofile(base .. "03_protocol.lua")

local missions = {
	"missions/kitno_paw_and_fur.lua",
	"missions/kitno_meriana_rebels.lua",
	"missions/spike_tasks.lua",
	"missions/adventurers_guild.lua",
}
for _, file in ipairs(missions) do
	dofile(base .. file)
end

IdleMission.registerCatalogRows()
