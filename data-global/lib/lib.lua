-- Core API functions implemented in Lua
dofile(DATA_DIRECTORY .. "/lib/core/load.lua")

-- Others library
dofile(DATA_DIRECTORY .. "/lib/others/load.lua")

-- Quests library
dofile(DATA_DIRECTORY .. "/lib/quests/quest.lua")

-- Tables library
dofile(DATA_DIRECTORY .. "/lib/tables/load.lua")

-- Custom product libs (combat automation, expeditions, hireling, player home, quests, ...)
dofile(DATA_DIRECTORY .. "/lib/idleot/load.lua")
