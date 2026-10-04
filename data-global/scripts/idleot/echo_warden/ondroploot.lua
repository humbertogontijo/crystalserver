-- ============================================================================
-- Echo Warden loot: Basic Imbuement Scroll + random proficiency catalyst.
-- Forge dust (15) is granted on death via EchoWarden.grantDust — not a corpse item.
-- ============================================================================

local callback = EventCallback("MonsterOnDropLootEchoWarden")

function callback.monsterOnDropLoot(monster, corpse)
	if not monster or not corpse then
		return
	end
	if monster:getStorageValue(EchoWarden.STORAGE_IS_WARDEN) ~= 1 then
		return
	end

	local scrollId = math.random(EchoWarden.BASIC_SCROLL_MIN, EchoWarden.BASIC_SCROLL_MAX)
	corpse:addItem(scrollId, 1)

	local catalysts = EchoWarden.CATALYST_IDS
	corpse:addItem(catalysts[math.random(1, #catalysts)], 1)

	local existing = corpse:getAttribute(ITEM_ATTRIBUTE_LOOTMESSAGE_SUFFIX) or ""
	local suffix = string.len(existing) > 0 and (existing .. " Echo Warden kill") or "Echo Warden kill"
	corpse:setAttribute(ITEM_ATTRIBUTE_LOOTMESSAGE_SUFFIX, suffix)
end

callback:register()
