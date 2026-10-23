-- Day/night swaps place climate without a new instance (parallel to PlaceSound).
local periodChange = GlobalEvent("PlaceClimatePeriodChange")

function periodChange.onPeriodChange(period)
	if PlaceClimate then
		PlaceClimate.refreshOnline(period)
	end
	return true
end

periodChange:register()

local logout = CreatureEvent("PlaceClimateLogout")

function logout.onLogout(player)
	if PlaceClimate then
		PlaceClimate.forget(player)
	end
	return true
end

logout:register()

local login = CreatureEvent("PlaceClimateLogin")

function login.onLogin(player)
	player:registerEvent("PlaceClimateLogout")
	return true
end

login:register()
