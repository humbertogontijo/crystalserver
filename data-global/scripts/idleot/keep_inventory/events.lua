-- Players keep equipment and containers on death (no corpse drops).
-- The stock login (data/scripts) registers DropLoot after island login events run,
-- so it is detached on the next tick.
local loginEvent = CreatureEvent("KeepInventoryLogin")

function loginEvent.onLogin(player)
	player:registerEvent("KeepInventoryDeath")
	addEvent(function(playerId)
		local target = Player(playerId)
		if target then
			target:unregisterEvent("DropLoot")
		end
	end, 0, player:getId())
	return true
end

loginEvent:register()

local deathEvent = CreatureEvent("KeepInventoryDeath")

function deathEvent.onDeath(player)
	if not player:getSlotItem(CONST_SLOT_BACKPACK) then
		player:addItem(ITEM_BAG, 1, false, CONST_SLOT_BACKPACK)
	end
	return true
end

deathEvent:register()
