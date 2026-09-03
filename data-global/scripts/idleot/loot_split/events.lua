-- Live party loot split: runs after stock onDropLoot fillers, before async C++ auto-loot.
-- Hook: monsterPostDropLoot (see Creature death → Monster::dropLoot → callbacks → dispatcher QuickLoot).

local callback = EventCallback("LootSplitPostDropLoot")

function callback.monsterPostDropLoot(monster, corpse)
	if LootSplit and LootSplit.onDropLoot then
		LootSplit.onDropLoot(monster, corpse)
	end
end

callback:register()
