-- Startup + login hooks for ProductHirelingSync (see lib/idleot/hireling/sync.lua).

local startup = GlobalEvent("ProductHirelingSyncStartup")

function startup.onStartup()
	ProductHirelingSync.loadAllFromDatabase()
	return true
end

startup:register()

local loginEvent = CreatureEvent("ProductHirelingSyncLogin")

function loginEvent.onLogin(player)
	-- Load hireling rows for runtime when DB hirelings exist (legacy / store purchases).
	ProductHirelingSync.ensurePlayerHirelingsLoaded(player)
	return true
end

loginEvent:register()
