TokenServices = TokenServices or {}

local familyIds

--- Every item id that shows the renew menu option: depleted, recharged, equipped and extra family ids.
function TokenServices.renewableFamilies()
	if familyIds then
		return familyIds
	end
	local seen, list = {}, {}
	local function add(id)
		if id and id > 0 and not seen[id] then
			seen[id] = true
			list[#list + 1] = id
		end
	end
	for fromId, def in pairs(TokenServicesConfig.Renewables) do
		add(fromId)
		add(def.to)
		add(ItemType(def.to):getTransformEquipId())
		for _, id in ipairs(def.family or {}) do
			add(id)
		end
	end
	table.sort(list)
	familyIds = list
	return list
end

--- Depleted renewables carried anywhere (slots and containers): { fromId, count, def }.
function TokenServices.pendingRenewals(player)
	local list = {}
	for fromId, def in pairs(TokenServicesConfig.Renewables) do
		local count = player:getItemCount(fromId)
		if count > 0 then
			list[#list + 1] = { fromId = fromId, count = count, def = def }
		end
	end
	table.sort(list, function(a, b)
		return a.def.name < b.def.name
	end)
	return list
end

--- Gold needed to renew one renewable right now.
function TokenServices.renewCost(player, def)
	if def.tokens then
		return TokenMarket.quote(player, TokenServicesConfig.SILVER_TOKEN, def.tokens).gold
	end
	return def.gold or 0
end

local function payRenewal(player, def)
	if def.tokens then
		return TokenMarket.acquire(player, TokenServicesConfig.SILVER_TOKEN, def.tokens)
	end
	local price = def.gold or 0
	if price > (player:getMoney() or 0) + (player:getBankBalance() or 0) then
		return false, string.format("You need %s gold.", FormatNumber(price))
	end
	if price > 0 and not player:removeMoney(price) then
		return false, "Payment failed."
	end
	return true, price
end

--- Recharge every carried depleted item of one kind (fromId) or of every kind (nil).
--- Stops at the first failed payment. Returns ok, message, renewedCount.
function TokenServices.renew(player, fromId)
	local kinds = {}
	if fromId then
		local def = TokenServicesConfig.Renewables[fromId]
		if not def then
			return false, "That item cannot be renewed.", 0
		end
		kinds[1] = { fromId = fromId, def = def }
	else
		kinds = TokenServices.pendingRenewals(player)
	end

	local renewed, spent, failure = 0, 0, nil
	local names = {}
	for _, kind in ipairs(kinds) do
		local item = player:getItemById(kind.fromId, true)
		local kindCount = 0
		while item and not failure do
			local ok, result = payRenewal(player, kind.def)
			if not ok then
				failure = string.format("Could not renew %s: %s", kind.def.name, result)
				break
			end
			spent = spent + result
			if not item:transform(kind.def.to) then
				failure = string.format("Could not renew %s.", kind.def.name)
				break
			end
			kindCount = kindCount + 1
			item = player:getItemById(kind.fromId, true)
		end
		if kindCount > 0 then
			renewed = renewed + kindCount
			names[#names + 1] = kindCount > 1 and string.format("%dx %s", kindCount, kind.def.name) or kind.def.name
		end
		if failure then
			break
		end
	end

	if renewed == 0 then
		return false, failure or "Nothing to renew.", 0
	end
	local message = string.format("Renewed %s for %s gold.", table.concat(names, ", "), FormatNumber(spent))
	if failure then
		message = message .. " " .. failure
	end
	return true, message, renewed
end
