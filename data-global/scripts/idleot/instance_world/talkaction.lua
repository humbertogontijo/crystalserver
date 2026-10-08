-- /instance [channel]: show the caster's instance, or switch channel within the same
-- {kind, subarea} without moving. Channels are numbered as on the top bar (1-based).
local instanceCommand = TalkAction("/instance")

local function channelLabel(channel)
	return string.format("%02d", (tonumber(channel) or 0) + 1)
end

local function describe(player)
	local key = Instance.of(player)
	if Instance.isWorld(key) then
		return "the open world template (" .. key .. ")"
	end
	local desc = InstanceWorld.describeCurrent(player)
	local parsed = Instance.parse(key)
	local name = desc and desc.name or ("#" .. channelLabel(parsed.channel))
	return string.format("%s / %s / channel %s (%s)", parsed.kind, name, channelLabel(parsed.channel), key)
end

local function listChannels(key)
	local parsed = Instance.parse(key)
	local parts = {}
	for _, row in ipairs(Game.getInstanceChannels(parsed.kind, parsed.subareaId) or {}) do
		local label = channelLabel(row.channel) .. ":" .. tostring(row.players)
		if row.reserved then
			label = label .. "*"
		end
		parts[#parts + 1] = label
	end
	if #parts == 0 then
		return ""
	end
	return " Live channels (players, * = private): " .. table.concat(parts, " ")
end

function instanceCommand.onSay(player, words, param)
	logCommand(player, words, param)

	local current = Instance.of(player)
	param = param:trim()
	if param == "" then
		local text = "You are on " .. describe(player) .. "."
		if not Instance.isWorld(current) then
			text = text .. listChannels(current)
		end
		player:sendTextMessage(MESSAGE_ADMINISTRATOR, text .. " Usage: /instance <channel>")
		return true
	end

	local display = tonumber(param)
	if not display or display < 1 or display > 65536 or display ~= math.floor(display) then
		player:sendCancelMessage("Channel must be a number from 1 to 65536.")
		return true
	end
	if Instance.isWorld(current) then
		player:sendCancelMessage("The open world template has no channels.")
		return true
	end

	local parsed = Instance.parse(current)
	local key, err = InstanceWorld.switchChannelNow(player, display - 1, { bypass = true })
	if not key then
		player:sendCancelMessage(err)
		return true
	end

	if ExpeditionProtocol and ExpeditionProtocol.sendGodFlags then
		ExpeditionProtocol.sendGodFlags(player)
	end
	player:sendTextMessage(MESSAGE_ADMINISTRATOR, string.format("Channel %s -> %s.", channelLabel(parsed.channel), describe(player)))
	return true
end

instanceCommand:separator(" ")
instanceCommand:groupType("god")
instanceCommand:register()
