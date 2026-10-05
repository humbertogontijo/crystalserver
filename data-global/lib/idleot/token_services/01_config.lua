TokenServicesConfig = TokenServicesConfig or {}

TokenServicesConfig.OPCODE = 127
TokenServicesConfig.GOLD_TOKEN = 22721
TokenServicesConfig.SILVER_TOKEN = 22516

-- Gold per token when the market has no cheaper sell offer (also caps market purchases).
TokenServicesConfig.FallbackPrice = {
	[22721] = 50000,
	[22516] = 50000,
}

-- Depleted item id -> recharge. `tokens` are silver tokens (Cledwyn), `gold` is plain gold (Aldo).
-- `family` lists extra ids (fresh / equipped / worn) that also show the renew menu option.
TokenServicesConfig.Renewables = {
	[29429] = { name = "pendulet", to = 30344, tokens = 2 },
	[29428] = { name = "sleep shawl", to = 30342, tokens = 2 },
	[31621] = { name = "blister ring", to = 31557, tokens = 2 },
	[30401] = { name = "theurgic amulet", to = 30403, tokens = 2 },
	[32636] = { name = "ring of souls", to = 32621, tokens = 2 },
	[39235] = { name = "turtle amulet", to = 39233, tokens = 2 },
	[39179] = { name = "spiritthorn ring", to = 39177, tokens = 5 },
	[39182] = { name = "alicorn ring", to = 39180, tokens = 5 },
	[39185] = { name = "arcanomancer sigil", to = 39183, tokens = 5 },
	[39188] = { name = "arboreal ring", to = 39187, tokens = 5 },
	[6530] = { name = "soft boots", to = 6529, gold = 10000, family = { 3549 } },
}

-- Imbuement material -> full stack bought for carried gold tokens (Yana sells each tier layer for 2 gold tokens).
-- Ids and counts match data/XML/imbuements.xml (strike, vampirism, void).
TokenServicesConfig.ImbuementMaterials = {
	[11444] = { count = 20, goldTokens = 2 },
	[10311] = { count = 25, goldTokens = 2 },
	[22728] = { count = 5, goldTokens = 2 },
	[9685] = { count = 25, goldTokens = 2 },
	[9633] = { count = 15, goldTokens = 2 },
	[9663] = { count = 5, goldTokens = 2 },
	[11492] = { count = 25, goldTokens = 2 },
	[20200] = { count = 25, goldTokens = 2 },
	[22730] = { count = 5, goldTokens = 2 },
}
