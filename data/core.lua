DATA_DIRECTORY = configManager.getString(configKeys.DATA_DIRECTORY)
CORE_DIRECTORY = configManager.getString(configKeys.CORE_DIRECTORY)

dofile(CORE_DIRECTORY .. "/global.lua")
dofile(CORE_DIRECTORY .. "/libs/libs.lua")
dofile(CORE_DIRECTORY .. "/stages.lua")

-- Product libs (data-global/lib/idleot) load after the stock libs and stages so they can extend them.
dofile(DATA_DIRECTORY .. "/lib/idleot/load.lua")
