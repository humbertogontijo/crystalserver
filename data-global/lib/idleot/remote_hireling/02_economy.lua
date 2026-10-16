-- Remote hireling sell economy: cooldown, tax, inventory sell-all (no open shop).

RemoteHirelingEconomy = RemoteHirelingEconomy or {}

local function kv(player)
	if not player then
		return nil
	end
	return player:kv():scoped(RemoteHirelingConfig.KV_SCOPE)
end

local function nowUnix()
	return os.time()
end

function RemoteHirelingEconomy.getCooldownUntil(player)
	local store = kv(player)
	if not store then
		return 0
	end
	return math.floor(tonumber(store:get(RemoteHirelingConfig.KV_COOLDOWN_UNTIL)) or 0)
end

function RemoteHirelingEconomy.setCooldownUntil(player, untilTs)
	local store = kv(player)
	if not store then
		return
	end
	untilTs = math.floor(tonumber(untilTs) or 0)
	if untilTs <= 0 then
		store:remove(RemoteHirelingConfig.KV_COOLDOWN_UNTIL)
	else
		store:set(RemoteHirelingConfig.KV_COOLDOWN_UNTIL, untilTs)
	end
end

function RemoteHirelingEconomy.getAutoSell(player)
	local store = kv(player)
	if not store then
		return false
	end
	local v = store:get(RemoteHirelingConfig.KV_AUTO_SELL)
	return v == true or v == 1 or v == "1"
end

function RemoteHirelingEconomy.setAutoSell(player, enabled)
	local store = kv(player)
	if not store then
		return
	end
	store:set(RemoteHirelingConfig.KV_AUTO_SELL, enabled and 1 or 0)
end

local function getBoolFlag(player, key, defaultTrue)
	local store = kv(player)
	if not store then
		return defaultTrue == true
	end
	local v = store:get(key)
	if v == nil then
		return defaultTrue == true
	end
	return v == true or v == 1 or v == "1"
end

local function setBoolFlag(player, key, enabled)
	local store = kv(player)
	if not store then
		return
	end
	store:set(key, enabled and 1 or 0)
end

function RemoteHirelingEconomy.getSellOnNoGold(player)
	return getBoolFlag(player, RemoteHirelingConfig.KV_SELL_ON_NO_GOLD, true)
end

function RemoteHirelingEconomy.setSellOnNoGold(player, enabled)
	setBoolFlag(player, RemoteHirelingConfig.KV_SELL_ON_NO_GOLD, enabled)
end

function RemoteHirelingEconomy.getSellOnNoCap(player)
	return getBoolFlag(player, RemoteHirelingConfig.KV_SELL_ON_NO_CAP, true)
end

function RemoteHirelingEconomy.setSellOnNoCap(player, enabled)
	setBoolFlag(player, RemoteHirelingConfig.KV_SELL_ON_NO_CAP, enabled)
end

--- When false, emergency auto-sell skips while the free-sell cooldown (tax) is active.
--- Default true: shortage sells should not wait an hour for the free rate.
function RemoteHirelingEconomy.getAcceptTaxOnCooldown(player)
	return getBoolFlag(player, RemoteHirelingConfig.KV_ACCEPT_TAX_ON_COOLDOWN, true)
end

function RemoteHirelingEconomy.setAcceptTaxOnCooldown(player, enabled)
	setBoolFlag(player, RemoteHirelingConfig.KV_ACCEPT_TAX_ON_COOLDOWN, enabled)
end

--- Tax percent while remote cooldown is active (0 when ready).
function RemoteHirelingEconomy.getTaxPercent(player)
	local untilTs = RemoteHirelingEconomy.getCooldownUntil(player)
	if untilTs > nowUnix() then
		return RemoteHirelingConfig.TAX_PERCENT or 20
	end
	return 0
end

function RemoteHirelingEconomy.isOnCooldown(player)
	return RemoteHirelingEconomy.getTaxPercent(player) > 0
end

--- Start free-sell cooldown. No-op if already taxed.
function RemoteHirelingEconomy.startCooldownIfFree(player)
	if RemoteHirelingEconomy.isOnCooldown(player) then
		return false
	end
	local secs = RemoteHirelingConfig.COOLDOWN_SECONDS or 3600
	RemoteHirelingEconomy.setCooldownUntil(player, nowUnix() + secs)
	return true
end

--- Status payload fields for opcode 115 (cooldownUntil in unix ms).
function RemoteHirelingEconomy.statusFields(player)
	local untilTs = RemoteHirelingEconomy.getCooldownUntil(player)
	return {
		cooldownUntil = untilTs * 1000,
		taxPercent = RemoteHirelingEconomy.getTaxPercent(player),
		autoSell = RemoteHirelingEconomy.getAutoSell(player),
		sellOnNoGold = RemoteHirelingEconomy.getSellOnNoGold(player),
		sellOnNoCap = RemoteHirelingEconomy.getSellOnNoCap(player),
		acceptTaxOnCooldown = RemoteHirelingEconomy.getAcceptTaxOnCooldown(player),
		cooldownSeconds = RemoteHirelingConfig.COOLDOWN_SECONDS or 3600,
	}
end

--- Apply tax to a catalog table (clone; buy prices unchanged).
function RemoteHirelingEconomy.applyTaxToCatalog(catalog, taxPercent)
	taxPercent = math.floor(tonumber(taxPercent) or 0)
	if taxPercent <= 0 or type(catalog) ~= "table" then
		return catalog
	end
	local keep = math.max(0, 100 - taxPercent)
	local out = {}
	for i, entry in ipairs(catalog) do
		local copy = {}
		for k, v in pairs(entry) do
			copy[k] = v
		end
		local sell = tonumber(copy.sell) or 0
		if sell > 0 then
			copy.sell = math.max(1, math.floor(sell * keep / 100))
		end
		out[i] = copy
	end
	return out
end

local function compactItemIds(raw)
	local out = {}
	local maxIds = RemoteHirelingConfig.MAX_FILTER_IDS or 512
	if type(raw) ~= "table" then
		return out
	end
	for _, value in ipairs(raw) do
		local id = tonumber(value)
		if id and id > 0 then
			out[#out + 1] = math.floor(id)
			if #out >= maxIds then
				break
			end
		end
	end
	return out
end

function RemoteHirelingEconomy.setSellFilter(player, filterMode, itemIds)
	local store = kv(player)
	if not store then
		return
	end
	filterMode = tonumber(filterMode) or 0
	if filterMode ~= 1 then
		filterMode = 0
	end
	store:set(RemoteHirelingConfig.KV_SELL_FILTER_MODE, filterMode)
	local ids = compactItemIds(itemIds)
	if #ids == 0 then
		store:remove(RemoteHirelingConfig.KV_SELL_FILTER_IDS)
	else
		store:set(RemoteHirelingConfig.KV_SELL_FILTER_IDS, ids)
	end
end

function RemoteHirelingEconomy.getSellFilter(player)
	local store = kv(player)
	if not store then
		return 0, {}
	end
	local mode = tonumber(store:get(RemoteHirelingConfig.KV_SELL_FILTER_MODE)) or 0
	if mode ~= 1 then
		mode = 0
	end
	local raw = store:get(RemoteHirelingConfig.KV_SELL_FILTER_IDS)
	return mode, compactItemIds(raw)
end

local function buildListedSet(itemIds)
	local listed = {}
	local count = 0
	for _, id in ipairs(compactItemIds(itemIds)) do
		listed[id] = true
		count = count + 1
	end
	return listed, count
end

local function buildSellPriceMap()
	local prices = {}
	local catalog = (HirelingShopItems["buy loot"]) or HirelingBuyLootItems
	if type(catalog) == "table" then
		for _, entry in ipairs(catalog) do
			local sell = math.floor(tonumber(entry.sell) or 0)
			local clientId = tonumber(entry.clientId)
			if clientId and clientId > 0 and sell > 0 then
				prices[clientId] = sell
			end
		end
	end
	-- Prefer live ItemType.sellPrice (CIP denorm + NPC shops) when higher / present.
	for clientId, catalogSell in pairs(prices) do
		local typed = math.floor(tonumber(ItemType(clientId):getSellPrice()) or 0)
		if typed > catalogSell then
			prices[clientId] = typed
		end
	end
	return prices
end

local function passesFilter(typeId, filterMode, listed, listCount)
	if listCount == 0 then
		-- Skipped + empty = sell everything; Accepted + empty = sell nothing.
		return filterMode ~= 1
	end
	local hit = listed[typeId] == true
	if filterMode == 1 then
		return hit
	end
	return not hit
end

local function resolvePrice(prices, typeId)
	if prices[typeId] then
		return prices[typeId]
	end
	-- Fall back to ItemType even for items not in the hireling catalog.
	return math.floor(tonumber(ItemType(typeId):getSellPrice()) or 0)
end

local function isEquippedNonContainer(player, item)
	if not player or not item then
		return false
	end
	if item:isContainer() then
		return false
	end
	for slot = CONST_SLOT_FIRST, CONST_SLOT_LAST do
		if player:getSlotItem(slot) == item then
			return true
		end
	end
	return false
end

--- Character Gold Pouch (store inbox) via getLootPouch.
local function findLootPouch(player)
	if not player then
		return nil
	end
	return player:getLootPouch()
end

local function collectStacks(player, ignoreEquipped)
	local stacks = {}
	local function scan(item)
		if not item then
			return
		end
		if ignoreEquipped and isEquippedNonContainer(player, item) then
			return
		end
		if item:isContainer() then
			local size = item:getSize() or 0
			for i = 0, size - 1 do
				scan(item:getItem(i))
			end
			if size == 0 then
				local id = item:getId()
				stacks[id] = (stacks[id] or 0) + (item:getCount() or 1)
			end
			return
		end
		if item:getTier() > 0 then
			return
		end
		local id = item:getId()
		stacks[id] = (stacks[id] or 0) + (item:getCount() or 1)
	end

	for slot = CONST_SLOT_FIRST, CONST_SLOT_LAST do
		scan(player:getSlotItem(slot))
	end
	scan(player:getStoreInbox())
	return stacks
end

--- Sell inventory against hireling loot catalog. Returns netGold, items, taxPercent.
function RemoteHirelingEconomy.sellAll(player, ignoreEquipped, filterMode, itemIds)
	if not player or not player:isPlayer() then
		return 0, 0, 0
	end

	ignoreEquipped = ignoreEquipped ~= false
	filterMode = tonumber(filterMode) or 0
	if filterMode ~= 1 then
		filterMode = 0
	end

	local listed, listCount = buildListedSet(itemIds)
	local prices = buildSellPriceMap()
	if next(prices) == nil then
		return 0, 0, RemoteHirelingEconomy.getTaxPercent(player)
	end

	local taxPercent = RemoteHirelingEconomy.getTaxPercent(player)
	local keep = math.max(0, 100 - taxPercent)
	local stacks = collectStacks(player, ignoreEquipped)

	local gross = 0
	local soldItems = 0

	for typeId, count in pairs(stacks) do
		if count > 0 and passesFilter(typeId, filterMode, listed, listCount) then
			local unit = resolvePrice(prices, typeId)
			if unit > 0 then
				if player:removeItem(typeId, count, -1, ignoreEquipped) then
					gross = gross + unit * count
					soldItems = soldItems + count
				end
			end
		end
	end

	if soldItems <= 0 or gross <= 0 then
		return 0, 0, taxPercent
	end

	local net = math.floor(gross * keep / 100)
	if net > 0 then
		player:addMoney(net)
	end

	if taxPercent == 0 and net > 0 then
		RemoteHirelingEconomy.startCooldownIfFree(player)
	end

	return net, soldItems, RemoteHirelingEconomy.getTaxPercent(player)
end

--- Sell loot-pouch contents against the hireling loot catalog (respects sell list filter).
function RemoteHirelingEconomy.sellLootPouch(player, filterMode, itemIds)
	if not player or not player:isPlayer() then
		return 0, 0, 0
	end

	local pouch = findLootPouch(player)
	if not pouch then
		return 0, 0, RemoteHirelingEconomy.getTaxPercent(player)
	end

	filterMode = tonumber(filterMode) or 0
	if filterMode ~= 1 then
		filterMode = 0
	end

	local listed, listCount = buildListedSet(itemIds)
	local prices = buildSellPriceMap()
	if next(prices) == nil then
		return 0, 0, RemoteHirelingEconomy.getTaxPercent(player)
	end

	local taxPercent = RemoteHirelingEconomy.getTaxPercent(player)
	local keep = math.max(0, 100 - taxPercent)
	local gross = 0
	local soldItems = 0
	local toRemove = {}

	for i = pouch:getSize() - 1, 0, -1 do
		local it = pouch:getItem(i)
		if it then
			local typeId = it:getId()
			local count = it:getCount() or 1
			if it:getTier() == 0 and count > 0 and passesFilter(typeId, filterMode, listed, listCount) then
				local unit = resolvePrice(prices, typeId)
				if unit > 0 then
					gross = gross + unit * count
					soldItems = soldItems + count
					toRemove[#toRemove + 1] = it
				end
			end
		end
	end

	for _, it in ipairs(toRemove) do
		it:remove()
	end

	if soldItems <= 0 or gross <= 0 then
		return 0, 0, taxPercent
	end

	local net = math.floor(gross * keep / 100)
	if net > 0 then
		player:addMoney(net)
	end

	if taxPercent == 0 and net > 0 then
		RemoteHirelingEconomy.startCooldownIfFree(player)
	end

	return net, soldItems, RemoteHirelingEconomy.getTaxPercent(player)
end

-- Per-player debounce: gold/combat ticks spam often; cap only rate-limits empty/tax msgs.
local lastEmergencySellAt = {}
local lastEmptySellMsgAt = {}
local lastTaxWaitMsgAt = {}

local function rateLimitedMsg(store, pid, now, cooldownSecs, player, message)
	local last = store[pid] or 0
	if now - last < cooldownSecs then
		return
	end
	store[pid] = now
	player:sendTextMessage(MESSAGE_STATUS, message)
end

--- Sell loot pouch using saved filter before expedition stop-on-gold / stop-on-cap.
--- Auto-sell is pouch-only (never backpack / equipped). kind: "gold" | "cap".
--- Returns true when at least one item was sold.
function RemoteHirelingEconomy.maybeSellForShortage(player, kind)
	if not player or not player:isPlayer() then
		return false
	end
	if not RemoteHirelingEconomy.getAutoSell(player) then
		return false
	end
	if kind == "gold" then
		if not RemoteHirelingEconomy.getSellOnNoGold(player) then
			return false
		end
	elseif kind == "cap" then
		if not RemoteHirelingEconomy.getSellOnNoCap(player) then
			return false
		end
	else
		return false
	end

	local pid = player:getId()
	local now = nowUnix()
	local cooldown = RemoteHirelingConfig.EMERGENCY_SELL_COOLDOWN_SECONDS or 5

	-- Opt-in wait: do not auto-sell while free-sell cooldown would apply 20% tax.
	if RemoteHirelingEconomy.isOnCooldown(player)
		and not RemoteHirelingEconomy.getAcceptTaxOnCooldown(player) then
		rateLimitedMsg(
			lastTaxWaitMsgAt,
			pid,
			now,
			cooldown,
			player,
			"Auto-sell waiting for free hour (tax)."
		)
		return false
	end

	-- Gold/combat: debounce successful sells only so an empty pouch on tick N
	-- does not block a real sell when loot arrives shortly after.
	if kind == "gold" then
		local last = lastEmergencySellAt[pid] or 0
		if now - last < cooldown then
			return false
		end
	end


	local filterMode, itemIds = RemoteHirelingEconomy.getSellFilter(player)
	if filterMode == 1 and (not itemIds or #itemIds == 0) then
		rateLimitedMsg(
			lastEmptySellMsgAt,
			pid,
			now,
			cooldown,
			player,
			"Auto-sell: Accepted sell list is empty — add items or switch to Skipped."
		)
		return false
	end

	local gold, items, taxPercent = RemoteHirelingEconomy.sellLootPouch(player, filterMode, itemIds)
	if items <= 0 then
		-- Rate-limit empty diagnostic; do not arm gold success debounce.
		rateLimitedMsg(
			lastEmptySellMsgAt,
			pid,
			now,
			cooldown,
			player,
			"Auto-sell: nothing sellable in loot pouch (check Skipped vs Accepted sell list)."
		)
		return false
	end

	if kind == "gold" then
		lastEmergencySellAt[pid] = now
	end

	local msg
	if taxPercent > 0 then
		msg = string.format("Auto-sold %d items for %d gold (%d%% remote tax).", items, gold, taxPercent)
	else
		msg = string.format("Auto-sold %d items for %d gold.", items, gold)
	end
	player:sendTextMessage(MESSAGE_EVENT_ADVANCE, msg)
	return true
end
