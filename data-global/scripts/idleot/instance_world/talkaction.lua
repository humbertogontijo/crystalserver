-- /instance [id]: show or switch the caster's engine instance without moving them.
local instanceCommand = TalkAction("/instance")

local function describe(player)
	local engineId = player:getInstanceId() or 0
	local desc = InstanceWorld and InstanceWorld.describeCurrent and InstanceWorld.describeCurrent(player) or nil
	if not desc then
		return string.format("instance %d (open world)", engineId)
	end
	return string.format("instance %d (%s: %s, channel %d)", engineId, desc.kind, desc.name, desc.channel or 0)
end

function instanceCommand.onSay(player, words, param)
	logCommand(player, words, param)

	param = param:trim()
	if param == "" then
		player:sendTextMessage(MESSAGE_ADMINISTRATOR, "You are on " .. describe(player) .. ". Usage: /instance <id>")
		return true
	end

	local instanceId = tonumber(param)
	if not instanceId or instanceId < 0 or instanceId ~= math.floor(instanceId) then
		player:sendCancelMessage("Instance id must be a non-negative integer.")
		return true
	end

	local previous = player:getInstanceId() or 0
	if previous == instanceId then
		player:sendCancelMessage("You are already on instance " .. instanceId .. ".")
		return true
	end

	if not InstanceWorld.setInstanceInPlace(player, instanceId) then
		player:sendCancelMessage("Could not switch to instance " .. instanceId .. ".")
		return true
	end

	if InstanceWorld and InstanceWorld.sendBounds then
		InstanceWorld.sendBounds(player, true)
	end
	if ExpeditionProtocol and ExpeditionProtocol.sendGodFlags then
		ExpeditionProtocol.sendGodFlags(player)
	end
	player:sendTextMessage(MESSAGE_ADMINISTRATOR, string.format("Instance %d -> %s.", previous, describe(player)))
	return true
end

instanceCommand:separator(" ")
instanceCommand:groupType("god")
instanceCommand:register()
