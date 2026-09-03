-- Product: /c brings the target into the caster's instance (shared coords).
local pushCreature = TalkAction("/c")

function pushCreature.onSay(player, words, param)
	logCommand(player, words, param)

	if param == "" then
		player:sendCancelMessage("Command param required.")
		return true
	end

	local creature = Creature(param)
	if not creature then
		player:sendCancelMessage("A creature with that name could not be found.")
		return true
	end

	local oldPosition = creature:getPosition()
	local newPosition = creature:getClosestFreePosition(player:getPosition(), false)
	if newPosition.x == 0 then
		player:sendCancelMessage("You can not teleport " .. creature:getName() .. ".")
		return true
	end

	local instanceId = player.getInstanceId and player:getInstanceId() or 0
	local ok = false
	if InstanceWorld and InstanceWorld.enterInstance and instanceId ~= 0 then
		ok = InstanceWorld.enterInstance(creature, instanceId, newPosition) and true or false
	else
		ok = creature:teleportTo(newPosition) and true or false
	end

	if ok and not creature:isInGhostMode() then
		oldPosition:sendMagicEffect(CONST_ME_POFF)
		newPosition:sendMagicEffect(CONST_ME_TELEPORT)
	elseif not ok then
		player:sendCancelMessage("You can not teleport " .. creature:getName() .. ".")
	end
	if ok and creature.getPlayer and creature:getPlayer() then
		local moved = creature:getPlayer()
		if moved.sendMapDescription then
			local pos = moved:getPosition()
			if pos then
				moved:sendMapDescription(pos)
			end
		end
		if InstanceWorld and InstanceWorld.sendBounds then
			InstanceWorld.sendBounds(moved, true)
		end
	end
	return true
end

pushCreature:separator(" ")
pushCreature:groupType("gamemaster")
pushCreature:register()
