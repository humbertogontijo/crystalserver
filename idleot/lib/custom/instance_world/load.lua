local base = DATA_DIRECTORY .. "/lib/custom/instance_world/"
dofile(base .. "01_world.lua")
dofile(base .. "02_monster_think.lua")
dofile(base .. "03_rotten_blood_icons.lua")
-- apply() runs again from InstanceWorld.onStartup once MonsterTypes are loaded.
