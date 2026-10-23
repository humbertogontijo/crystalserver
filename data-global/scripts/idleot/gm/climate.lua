-- GOD climate scrub for weather / atmosphere tests.
-- Layers stack (fog ≠ clouds ≠ precip):
--   /climate                         -> print current climate
--   /climate clear                   -> wipe all layers
--   /climate fog [intensity]         -> ground mist only
--   /climate cloudy [intensity]      -> sky clouds only (alias: clouds)
--   /climate rain|snow|storm [i]     -> precip (keeps fog/clouds)
--   /climate wind <x> <y>

local talkaction = TalkAction("/climate")

local function parseIntensity(token)
	if not token or token == "" then
		return 0.65
	end
	local n = tonumber(token)
	if not n then
		return nil
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
	return string.format("precip=%s/%.2f fog=%.2f clouds=%.2f wind=(%.2f,%.2f)", tostring(p.kind or "clear"),
		tonumber(p.intensity) or 0, tonumber(p.fog) or 0, tonumber(p.clouds) or 0, tonumber(p.windX) or 0, tonumber(p.windY) or 0)
end

function talkaction.onSay(player, words, param)
	logCommand(player, words, param)

	if not PlaceClimate then
		player:sendCancelMessage("PlaceClimate is not loaded.")
		return true
	end

	param = (param or ""):trim()
	if param == "" then
		local ov = PlaceClimate.overrideOf(player)
		if ov then
			player:sendTextMessage(MESSAGE_EVENT_ADVANCE, "Climate override: " .. fmtPayload(ov))
			return true
		end
		local desc = InstanceWorld and InstanceWorld.describeCurrent(player) or nil
		local payload = PlaceClimate.selection(player, desc)
		player:sendTextMessage(MESSAGE_EVENT_ADVANCE, "Place climate: " .. fmtPayload(payload))
		return true
	end

	local parts = param:split(" ")
	local cmd = string.lower(parts[1] or "")

	if cmd == "wind" then
		local x = tonumber(parts[2] or "")
		local y = tonumber(parts[3] or "")
		if not x or not y then
			player:sendCancelMessage("Usage: /climate wind <x> <y>")
			return true
		end
		local n = PlaceClimate.broadcastOverride(player, { windX = x, windY = y, transitionMs = 800 })
		player:sendTextMessage(MESSAGE_EVENT_ADVANCE, string.format("Climate wind set to (%.2f, %.2f) for %d player(s).", x, y, n))
		return true
	end

	if cmd == "clear" then
		local n = PlaceClimate.broadcastOverride(player, { clearAll = true, transitionMs = 800 })
		player:sendTextMessage(MESSAGE_EVENT_ADVANCE, string.format("Climate cleared for %d player(s).", n))
		return true
	end

	if cmd == "cloudy" or cmd == "clouds" then
		local intensity = parseIntensity(parts[2])
		if intensity == nil then
			player:sendCancelMessage("Usage: /climate cloudy [intensity]")
			return true
		end
		local n = PlaceClimate.broadcastOverride(player, {
			clouds = intensity,
			windX = 0.35,
			windY = -0.05,
			transitionMs = 1000,
		})
		player:sendTextMessage(MESSAGE_EVENT_ADVANCE, string.format("Sky clouds=%.2f for %d player(s).", intensity, n))
		return true
	end

	if cmd == "fog" then
		local intensity = parseIntensity(parts[2])
		if intensity == nil then
			player:sendCancelMessage("Usage: /climate fog [intensity]")
			return true
		end
		local n = PlaceClimate.broadcastOverride(player, {
			fog = intensity,
			windX = 0.15,
			windY = 0.05,
			transitionMs = 1000,
		})
		player:sendTextMessage(MESSAGE_EVENT_ADVANCE, string.format("Ground fog=%.2f for %d player(s).", intensity, n))
		return true
	end

	if cmd == "rain" or cmd == "snow" or cmd == "storm" then
		local intensity = parseIntensity(parts[2])
		if intensity == nil then
			player:sendCancelMessage("Usage: /climate " .. cmd .. " [intensity]")
			return true
		end
		local n = PlaceClimate.broadcastOverride(player, {
			kind = cmd,
			intensity = intensity,
			windX = cmd == "snow" and 0.25 or 0.4,
			windY = -0.15,
			transitionMs = 1000,
		})
		player:sendTextMessage(MESSAGE_EVENT_ADVANCE, string.format("Precip %s=%.2f for %d player(s).", cmd, intensity, n))
		return true
	end

	player:sendCancelMessage("Usage: /climate [clear|fog|cloudy|rain|snow|storm] [intensity] | wind <x> <y>")
	return true
end

talkaction:separator(" ")
talkaction:groupType("god")
talkaction:register()
