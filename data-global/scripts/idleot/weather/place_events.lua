-- Day/night refresh, login push, and weather think for PlaceWeather.
local periodChange = GlobalEvent("PlaceWeatherPeriodChange")

function periodChange.onPeriodChange(period)
	if PlaceWeather then
		PlaceWeather.refreshOnline(period)
	end
	return true
end

periodChange:register()

local logout = CreatureEvent("PlaceWeatherLogout")

function logout.onLogout(player)
	if PlaceWeather then
		PlaceWeather.forget(player)
	end
	return true
end

logout:register()

local login = CreatureEvent("PlaceWeatherLogin")

function login.onLogin(player)
	player:registerEvent("PlaceWeatherLogout")
	if PlaceWeather then
		local pid = player:getId()
		addEvent(function()
			local p = Player(pid)
			if p and PlaceWeather then
				PlaceWeather.send(p, nil, nil, true)
			end
		end, 50)
	end
	return true
end

login:register()

local think = GlobalEvent("PlaceWeatherThink")

function think.onThink(interval)
	if PlaceWeather and PlaceWeather.think then
		PlaceWeather.think()
	end
	return true
end

think:interval(PlaceWeather and PlaceWeather.THINK_MS or 30000)
think:register()
