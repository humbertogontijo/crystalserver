-- GOD world-time scrub for lighting / raycast tests.
-- Usage:
--   /time              -> print current tibia time
--   /time 6:00         -> sunrise
--   /time 12:00        -> noon
--   /time 18:30        -> late day
--   /time 22:00        -> night
--   /time 870          -> minutes since midnight

local talkaction = TalkAction("/time")

local function parseMinutes(param)
	param = (param or ""):trim()
	if param == "" then
		return nil
	end
	local hour, minute = param:match("^(%d%d?):(%d%d)$")
	if hour then
		hour, minute = tonumber(hour), tonumber(minute)
		if not hour or not minute or hour > 23 or minute > 59 then
			return false
		end
		return hour * 60 + minute
	end
	local minutes = tonumber(param)
	if not minutes or minutes < 0 then
		return false
	end
	return math.floor(minutes) % 1440
end

function talkaction.onSay(player, words, param)
	logCommand(player, words, param)

	local minutes = parseMinutes(param)
	if minutes == nil then
		player:sendTextMessage(MESSAGE_EVENT_ADVANCE, "World time is " .. getFormattedWorldTime() .. ".")
		return true
	end
	if minutes == false then
		player:sendCancelMessage("Usage: /time [HH:MM|minutes]. Example: /time 6:00")
		return true
	end

	Game.setWorldTime(minutes)
	player:sendTextMessage(MESSAGE_EVENT_ADVANCE, "World time set to " .. getFormattedWorldTime() .. ".")
	return true
end

talkaction:separator(" ")
talkaction:groupType("god")
talkaction:register()
