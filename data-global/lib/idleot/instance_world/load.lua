local base = DATA_DIRECTORY .. "/lib/idleot/instance_world/"
dofile(base .. "01_world.lua")
dofile(base .. "03_rotten_blood_icons.lua")
-- apply() runs again from InstanceWorld.onStartup once MonsterTypes are loaded.
