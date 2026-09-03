-- Product: keep equipment and containers on death (no corpse drops).
-- Stock Crystal DropLoot / Blessings.PlayerDeath is intentionally bypassed.

local dropLoot = CreatureEvent("DropLoot")

function dropLoot.onDeath(player, corpse, killer, mostDamage, unjustified, mostDamage_unjustified)
	if not player:getSlotItem(CONST_SLOT_BACKPACK) then
		player:addItem(ITEM_BAG, 1, false, CONST_SLOT_BACKPACK)
	end
	return true
end

dropLoot:register()
