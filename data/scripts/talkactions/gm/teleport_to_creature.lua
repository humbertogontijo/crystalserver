-- Product: /goto also joins the target creature's instance (shared coords).
local teleportToCreature = TalkAction("/goto")

function teleportToCreature.onSay(player, words, param)
	logCommand(player, words, param)

	if param == "" then
		player:sendCancelMessage("Command param required.")
		return true
	end

	local target = Creature(param)
	if not target then
		player:sendCancelMessage("Creature not found.")
		return true
	end

	local dest = target:getPosition()
	local instanceId = Instance.of(target)
	local ok = false
	if InstanceWorld and InstanceWorld.enterInstance and not Instance.isWorld(instanceId) then
		ok = InstanceWorld.enterInstance(player, instanceId, dest) and true or false
	else
		ok = player:teleportTo(dest) and true or false
	end
	if not ok then
		player:sendCancelMessage("You can not teleport to " .. target:getName() .. ".")
		return true
	end
	-- OTC needs map tiles + instance mask before walk packets animate (especially GOD /goto).
	if player.sendMapDescription then
		local pos = player:getPosition()
		if pos then
			player:sendMapDescription(pos)
		end
	end
	if InstanceWorld and InstanceWorld.sendBounds then
		InstanceWorld.sendBounds(player, true)
	end
	if ExpeditionProtocol and ExpeditionProtocol.sendGodFlags then
		ExpeditionProtocol.sendGodFlags(player)
	end
	return true
end

teleportToCreature:separator(" ")
teleportToCreature:groupType("gamemaster")
teleportToCreature:register()
