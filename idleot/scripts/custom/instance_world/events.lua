local startup = GlobalEvent("InstanceWorldStartup")

function startup.onStartup()
	if InstanceWorld and InstanceWorld.onStartup then
		local ok, err = pcall(InstanceWorld.onStartup)
		if not ok then
			logger.error("[InstanceWorld] onStartup failed: {}", err)
		end
	end
	return true
end

startup:register()

local loginEvent = CreatureEvent("InstanceWorldLogin")

function loginEvent.onLogin(player)
	local ok, err = pcall(function()
		if InstanceWorld and InstanceWorld.bindLogin then
			InstanceWorld.bindLogin(player)
		end
		if InstanceWorld and InstanceWorld.rescueIfStranded then
			InstanceWorld.rescueIfStranded(player)
			local pid = player:getId()
			for _, delay in ipairs({ 100, 750 }) do
				addEvent(function()
					local p = Player(pid)
					if p then
						InstanceWorld.rescueIfStranded(p)
					end
				end, delay)
			end
		end
	end)
	if not ok then
		logger.error("[InstanceWorld] onLogin failed for {}: {}", player:getName(), err)
	end
	return true
end

loginEvent:register()

local moveCreatureCallback = EventCallback("InstanceWorldPlayerOnMoveCreature")

function moveCreatureCallback.playerOnMoveCreature(player, creature, fromPosition, toPosition)
	if not InstanceWorld or not InstanceWorld.canMoveCreature then
		return true
	end
	if InstanceWorld.canMoveCreature(player, creature, fromPosition, toPosition) then
		return true
	end
	if player and player.sendCancelMessage then
		player:sendCancelMessage(RETURNVALUE_NOTPOSSIBLE)
	end
	return false
end

moveCreatureCallback:register()

local moveItemCallback = EventCallback("InstanceWorldPlayerOnMoveItem")

function moveItemCallback.playerOnMoveItem(player, _item, _count, fromPosition, toPosition)
	if not InstanceWorld or not InstanceWorld.canWalk then
		return true
	end
	if toPosition and not InstanceWorld.canWalk(player, toPosition) then
		if player.sendCancelMessage then
			player:sendCancelMessage(RETURNVALUE_NOTPOSSIBLE)
		end
		return false
	end
	-- Map pickup/push: ground tile must stay inside occupancy (no walking out to drag).
	if fromPosition and fromPosition.x ~= 0xFFFF and not InstanceWorld.canWalk(player, fromPosition) then
		if player.sendCancelMessage then
			player:sendCancelMessage(RETURNVALUE_NOTPOSSIBLE)
		end
		return false
	end
	return true
end

moveItemCallback:register()
