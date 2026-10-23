-- GOD weather scrub for the caster's current area (kind:subareaId).
-- Injects timed episodes / ambient boosts into PlaceWeather (same clock as /time).
--
--   /weather                         -> print phase + payload
--   /weather clear                   -> begin clear-down
--   /weather fog [intensity]         -> timed ground mist boost (alias: foggy)
--   /weather clouds [intensity]      -> timed sky cover boost (alias: cloudy)
--   /weather rain|snow|storm [i]     -> inject precip episode
--   /weather wind <x> <y>            -> (no-op note; wind follows affinity + phase)

local talkaction = TalkAction("/weather")

local function parseIntensity(raw)
	if raw == nil or raw == "" then
		return nil
	end
	local n = tonumber(raw)
	if not n then
		return false
	end
	if n > 1 then
		n = n / 100
	end
	if n < 0 then
		n = 0
	elseif n > 1 then
		n = 1
	end
	return n
end

local function fmtPayload(p)
	if type(p) ~= "table" then
		return "?"
	end
	return string.format("precip=%s/%.2f fog=%.2f clouds=%.2f wind=(%.2f,%.2f)", tostring(p.kind or "clear"),
		tonumber(p.intensity) or 0, tonumber(p.fog) or 0, tonumber(p.clouds) or 0, tonumber(p.windX) or 0, tonumber(p.windY) or 0)
end

local function apply(player, fields, label)
	local n, infoOrErr = PlaceWeather.applyForPlayerArea(player, fields)
	if not n then
		player:sendCancelMessage(tostring(infoOrErr or "Could not set weather."))
		return true
	end
	player:sendTextMessage(MESSAGE_EVENT_ADVANCE,
		string.format("%s on %s (%d players).", label, infoOrErr.name or infoOrErr.key, n))
	return true
end

local function onWeatherSay(player, words, param)
	logCommand(player, words, param)

	if not PlaceWeather then
		player:sendCancelMessage("PlaceWeather is not loaded.")
		return true
	end

	param = (param or ""):trim()
	if param == "" then
		local info = PlaceWeather.areaInfo(player)
		if not info then
			player:sendTextMessage(MESSAGE_EVENT_ADVANCE, "No place weather here.")
			return true
		end
		local fam = info.affinity and info.affinity.precipFamily or "?"
		player:sendTextMessage(MESSAGE_EVENT_ADVANCE, string.format(
			"Weather [%s] %s (%s): phase=%s rem=%dmin family=%s | %s",
			getFormattedWorldTime and getFormattedWorldTime() or "?",
			info.name or info.key, info.key, tostring(info.phase), tonumber(info.phaseRemaining) or 0, fam,
			fmtPayload(info.payload)))
		return true
	end

	local parts = param:split(" ")
	local cmd = string.lower(parts[1] or "")
	if cmd == "cloudy" then
		cmd = "clouds"
	elseif cmd == "foggy" then
		cmd = "fog"
	end

	if cmd == "wind" then
		player:sendCancelMessage("Wind follows place affinity and weather phase; use /weather rain|storm to raise it.")
		return true
	end

	if cmd == "clear" then
		return apply(player, { clearAll = true, resetBase = true }, "Weather clearing")
	end

	if cmd == "clouds" then
		local intensity = parseIntensity(parts[2])
		if intensity == false then
			player:sendCancelMessage("Usage: /weather clouds [intensity]")
			return true
		end
		return apply(player, { clouds = intensity or 0.65 }, string.format("Clouds boost=%.2f", intensity or 0.65))
	end

	if cmd == "fog" then
		local intensity = parseIntensity(parts[2])
		if intensity == false then
			player:sendCancelMessage("Usage: /weather fog [intensity]")
			return true
		end
		return apply(player, { fog = intensity or 0.65 }, string.format("Fog boost=%.2f", intensity or 0.65))
	end

	if cmd == "rain" or cmd == "snow" or cmd == "storm" then
		local intensity = parseIntensity(parts[2])
		if intensity == false then
			player:sendCancelMessage("Usage: /weather " .. cmd .. " [intensity]")
			return true
		end
		return apply(player, {
			kind = cmd,
			intensity = intensity or 0.65,
		}, string.format("Episode %s/%.2f", cmd, intensity or 0.65))
	end

	player:sendCancelMessage("Usage: /weather [clear|fog|clouds|rain|snow|storm] [intensity]")
	return true
end

function talkaction.onSay(player, words, param)
	return onWeatherSay(player, words, param)
end

talkaction:separator(" ")
talkaction:groupType("god")
talkaction:register()
