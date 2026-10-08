TokenMarket = TokenMarket or {}

local function fallbackPrice(tokenId)
	return TokenServicesConfig.FallbackPrice[tokenId] or 0
end

local function availableGold(player)
	return (player:getMoney() or 0) + (player:getBankBalance() or 0)
end

local function refundToBank(player, amount)
	if amount and amount > 0 then
		player:setBankBalance(player:getBankBalance() + amount)
	end
end

--- Add items to the backpack one by one, overflowing into the store inbox.
--- Returns "backpack", "inbox" or "mixed".
function TokenMarket.deliver(player, itemId, count)
	local toBackpack, toInbox = 0, 0
	local inbox = player:getStoreInbox()
	local stackable = ItemType(itemId):isStackable()
	local step = stackable and count or 1
	local remaining = count
	while remaining > 0 do
		local n = math.min(step, remaining)
		if player:addItem(itemId, n, false) then
			toBackpack = toBackpack + n
		elseif inbox and inbox:addItem(itemId, n, INDEX_WHEREEVER, FLAG_NOLIMIT) then
			toInbox = toInbox + n
		else
			logger.error("[TokenMarket] could not deliver {}x {} to {}", n, itemId, player:getName())
		end
		remaining = remaining - n
	end
	if toInbox == 0 then
		return "backpack"
	end
	return toBackpack == 0 and "inbox" or "mixed"
end

--- Read-only price breakdown for `n` tokens. Carried tokens are spent first unless useCarried == false.
function TokenMarket.quote(player, tokenId, n, useCarried)
	n = math.max(0, math.floor(tonumber(n) or 0))
	local quote = { tokenId = tokenId, amount = n, carried = 0, market = 0, marketGold = 0, fixed = 0, fixedGold = 0, gold = 0 }
	if n == 0 or not player then
		return quote
	end
	if useCarried ~= false then
		quote.carried = math.min(player:getItemCount(tokenId), n)
	end
	local rest = n - quote.carried
	local unit = fallbackPrice(tokenId)
	if rest > 0 then
		local amount, gold = Game.quoteMarketSellOffers(player, tokenId, rest, unit)
		quote.market = amount or 0
		quote.marketGold = gold or 0
	end
	quote.fixed = rest - quote.market
	quote.fixedGold = quote.fixed * unit
	quote.gold = quote.marketGold + quote.fixedGold
	return quote
end

--- Gold for the next token bought (ignores carried stock) and its source: "market" or "fixed".
function TokenMarket.unitPrice(player, tokenId)
	local q = TokenMarket.quote(player, tokenId, 1, false)
	return q.gold, q.market > 0 and "market" or "fixed"
end

--- Spend `n` tokens: carried first, then the cheapest market sell offers, then the fixed price.
--- `extraGold` is charged in the same all-or-nothing transaction.
--- Returns ok, goldSpent (or error message), breakdown.
function TokenMarket.acquire(player, tokenId, n, extraGold)
	extraGold = math.max(0, math.floor(tonumber(extraGold) or 0))
	local q = TokenMarket.quote(player, tokenId, n)
	local total = q.gold + extraGold
	if total > availableGold(player) then
		return false, string.format("You need %s gold.", FormatNumber(total)), q
	end

	if extraGold > 0 and not player:removeMoney(extraGold) then
		return false, "Payment failed.", q
	end
	if q.carried > 0 and not player:removeItem(tokenId, q.carried) then
		refundToBank(player, extraGold)
		return false, "Could not take your tokens.", q
	end

	local bought, paid = 0, 0
	if q.market > 0 then
		bought, paid = Game.consumeMarketSellOffers(player, tokenId, q.market, fallbackPrice(tokenId))
	end

	local fixed = q.amount - q.carried - bought
	local fixedGold = fixed * fallbackPrice(tokenId)
	if fixedGold > 0 and not player:removeMoney(fixedGold) then
		-- Offers changed between quote and purchase: hand back what was already secured.
		TokenMarket.deliver(player, tokenId, q.carried + bought)
		refundToBank(player, extraGold)
		return false, "Token prices changed, please try again.", q
	end

	return true, extraGold + paid + fixedGold, {
		tokenId = tokenId,
		amount = q.amount,
		carried = q.carried,
		market = bought,
		marketGold = paid,
		fixed = fixed,
		fixedGold = fixedGold,
		gold = paid + fixedGold,
	}
end
