-- Day/night swaps the ambience bed without a new instance. Music stays until the place changes.
local periodChange = GlobalEvent("PlaceSoundPeriodChange")

function periodChange.onPeriodChange(period)
	if PlaceSound then
		PlaceSound.refreshOnline(period)
	end
	return true
end

periodChange:register()

local logout = CreatureEvent("PlaceSoundLogout")

function logout.onLogout(player)
	if PlaceSound then
		PlaceSound.forget(player)
	end
	return true
end

logout:register()

local login = CreatureEvent("PlaceSoundLogin")

function login.onLogin(player)
	player:registerEvent("PlaceSoundLogout")
	return true
end

login:register()

local walkEnd = EventCallback("PlaceSoundPlayerOnWalkEnd")

function walkEnd.playerOnWalkEnd(player, completed)
	if completed and PlaceSound then
		PlaceSound.onStep(player)
	end
end

walkEnd:register()
