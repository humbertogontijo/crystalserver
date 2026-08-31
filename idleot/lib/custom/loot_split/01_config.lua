LootSplitConfig = LootSplitConfig or {}

-- Extended opcode for optional client sync (stock PartyAnalyzer via sendLootStats is primary).
LootSplitConfig.OPCODE = 126

LootSplitConfig.ENABLED = true

-- At least one party member must be this close to the corpse to claim the kill.
-- Other same-instance members still get a seat (ranged support included).
LootSplitConfig.RANGE_XY = 30
LootSplitConfig.RANGE_Z = 1

-- Split by party seats: each member (incl. companions) is one share; companion
-- shares are delivered to their controller (leader+2 companions+friend → 3/4 + 1/4).
LootSplitConfig.WEIGHT_BY_SEATS = true

LootSplitConfig.GOLD_COIN_ID = ITEM_GOLD_COIN or 3031
LootSplitConfig.PLATINUM_COIN_ID = ITEM_PLATINUM_COIN or 3035
LootSplitConfig.CRYSTAL_COIN_ID = ITEM_CRYSTAL_COIN or 3043
LootSplitConfig.LOOT_POUCH_ID = ITEM_GOLD_POUCH or 23721
