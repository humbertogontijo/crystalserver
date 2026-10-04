-- Live party loot split: runs after stock onDropLoot fillers, before async C++ auto-loot.
-- Hook: monsterPostDropLoot (see Creature death → Monster::dropLoot → callbacks → dispatcher QuickLoot).

local callback = EventCallback("LootSplitPostDropLoot")

function callback.monsterPostDropLoot(monster, corpse)
	LootSplit.onDropLoot(monster, corpse)
end

callback:register()
