TokenServices = TokenServices or {}

--- Buy the full required stack of an imbuement material with carried gold tokens only
--- (players buy missing tokens on the market themselves).
--- Stowable materials go to the supply stash (counted by the imbuing shrine).
--- Returns ok, message, itemId, count.
function TokenServices.buyMaterial(player, itemId)
	itemId = math.floor(tonumber(itemId) or 0)
	local def = TokenServicesConfig.ImbuementMaterials[itemId]
	if not def then
		return false, "That material cannot be bought with gold tokens.", itemId, 0
	end

	local tokenId = TokenServicesConfig.GOLD_TOKEN
	local carried = player:getItemCount(tokenId)
	if carried < def.goldTokens then
		return false, string.format("You need %d gold tokens (you have %d).", def.goldTokens, carried), itemId, 0
	end
	if not player:removeItem(tokenId, def.goldTokens) then
		return false, "Could not take your gold tokens.", itemId, 0
	end

	local itemType = ItemType(itemId)
	local where = "supply stash"
	if not (itemType:isStowable() and player:addItemStash(itemId, def.count)) then
		local delivered = TokenMarket.deliver(player, itemId, def.count)
		where = delivered == "backpack" and "backpack" or "store inbox"
	end

	local message = string.format("Bought %dx %s for %d gold tokens, sent to your %s.", def.count, itemType:getName(), def.goldTokens, where)
	return true, message, itemId, def.count
end
