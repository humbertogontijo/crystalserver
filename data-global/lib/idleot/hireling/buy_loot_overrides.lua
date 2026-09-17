-- Optional IdleOT sell-price overrides keyed by clientId.
-- Applied after buy_loot.generated.lua. Example:
--   HirelingBuyLootOverrides = {
--     [3034] = { sell = 320 }, -- talon
--   }

HirelingBuyLootOverrides = HirelingBuyLootOverrides or {}
