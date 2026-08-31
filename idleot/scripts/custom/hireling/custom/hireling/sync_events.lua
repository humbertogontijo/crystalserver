-- Startup + login hooks for ProductHirelingSync (see lib/custom/hireling/sync.lua).

local startup = GlobalEvent("ProductHirelingSyncStartup")

function startup.onStartup()
	if ProductHirelingSync and ProductHirelingSync.loadAllFromDatabase then
		ProductHirelingSync.loadAllFromDatabase()
	end
	return true
end

startup:register()

local loginEvent = CreatureEvent("ProductHirelingSyncLogin")

function loginEvent.onLogin(player)
	if not ProductHirelingSync then
		return true
	end
	-- Load hireling rows for runtime when DB hirelings exist (legacy / store purchases).
	ProductHirelingSync.ensurePlayerHirelingsLoaded(player)
	return true
end

loginEvent:register()
