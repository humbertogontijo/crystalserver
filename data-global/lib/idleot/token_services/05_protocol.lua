TokenServices = TokenServices or {}

local reply = IdleUtil.jsonSender(TokenServicesConfig.OPCODE)

local function tokenSnapshot(player, tokenId)
	local price, source = TokenMarket.unitPrice(player, tokenId)
	return {
		id = tokenId,
		name = ItemType(tokenId):getName(),
		carried = player:getItemCount(tokenId),
		price = price,
		source = source,
	}
end

local function renewTotal(player, def, count)
	if def.tokens then
		return TokenMarket.quote(player, TokenServicesConfig.SILVER_TOKEN, def.tokens * count).gold
	end
	return (def.gold or 0) * count
end

local function pendingSnapshot(player)
	local list = {}
	for _, entry in ipairs(TokenServices.pendingRenewals(player)) do
		list[#list + 1] = {
			fromId = entry.fromId,
			toId = entry.def.to,
			name = entry.def.name,
			count = entry.count,
			tokens = entry.def.tokens or 0,
			unitGold = TokenServices.renewCost(player, entry.def),
			totalGold = renewTotal(player, entry.def, entry.count),
		}
	end
	return list
end

local function materialsSnapshot()
	local list = {}
	for itemId, def in pairs(TokenServicesConfig.ImbuementMaterials) do
		list[#list + 1] = { id = itemId, count = def.count, goldTokens = def.goldTokens }
	end
	table.sort(list, function(a, b)
		return a.id < b.id
	end)
	return list
end

function TokenServices.sendStatus(player)
	reply(player, {
		type = "status",
		gold = tokenSnapshot(player, TokenServicesConfig.GOLD_TOKEN),
		silver = tokenSnapshot(player, TokenServicesConfig.SILVER_TOKEN),
		families = TokenServices.renewableFamilies(),
		pending = pendingSnapshot(player),
		materials = materialsSnapshot(),
		balance = (player:getMoney() or 0) + (player:getBankBalance() or 0),
	})
end

local function notify(player, ok, text)
	player:sendTextMessage(ok and MESSAGE_EVENT_ADVANCE or MESSAGE_FAILURE, text)
end

function TokenServices.handleOpcode(player, buffer)
	if type(buffer) ~= "string" then
		return
	end
	local msg = JsonParser.decode(buffer)
	if type(msg) ~= "table" then
		return
	end

	local action = msg.action
	if action == "status" then
		TokenServices.sendStatus(player)
	elseif action == "renew" then
		local fromId = tonumber(msg.fromId)
		local ok, text = TokenServices.renew(player, fromId and math.floor(fromId) or nil)
		notify(player, ok, text)
		reply(player, { type = "renew", ok = ok, message = text or "" })
		TokenServices.sendStatus(player)
	elseif action == "buyMaterial" then
		local ok, text, itemId, count = TokenServices.buyMaterial(player, msg.itemId)
		notify(player, ok, text)
		reply(player, { type = "material", ok = ok, message = text or "", itemId = itemId, count = count })
		TokenServices.sendStatus(player)
	end
end
