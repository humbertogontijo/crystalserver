RemoteBlessings = RemoteBlessings or {}

local function escapeStr(s)
	s = tostring(s or "")
	s = s:gsub("\\", "\\\\")
	s = s:gsub('"', '\\"')
	s = s:gsub("\n", "\\n")
	s = s:gsub("\r", "\\r")
	s = s:gsub("\t", "\\t")
	return '"' .. s .. '"'
end

local function encodeValue(v, depth)
	depth = depth or 0
	if depth > 12 then
		return "null"
	end
	local t = type(v)
	if v == nil then
		return "null"
	elseif t == "boolean" then
		return v and "true" or "false"
	elseif t == "number" then
		if v ~= v or v == math.huge or v == -math.huge then
			return "null"
		end
		return tostring(v)
	elseif t == "string" then
		return escapeStr(v)
	elseif t == "table" then
		local isArray = true
		local n = 0
		for k, _ in pairs(v) do
			if type(k) ~= "number" then
				isArray = false
				break
			end
			if k > n then
				n = k
			end
		end
		if isArray then
			local parts = {}
			for i = 1, n do
				parts[#parts + 1] = encodeValue(v[i], depth + 1)
			end
			return "[" .. table.concat(parts, ",") .. "]"
		end
		local parts = {}
		for k, val in pairs(v) do
			parts[#parts + 1] = escapeStr(tostring(k)) .. ":" .. encodeValue(val, depth + 1)
		end
		return "{" .. table.concat(parts, ",") .. "}"
	end
	return "null"
end

local function encode(payload)
	return encodeValue(payload, 0)
end

local function decode(str)
	if type(str) ~= "string" or str == "" then
		return nil
	end
	-- Prefer team/expedition JSON if already loaded.
	if SquadJson and SquadJson.decode then
		return SquadJson.decode(str)
	end
	if JsonParser and JsonParser.decode then
		return JsonParser.decode(str)
	end
	-- Minimal fallback: only used when sibling libs are not present.
	return nil
end

local function reply(player, payload)
	player:sendExtendedOpcode(RemoteBlessingsConfig.OPCODE, encode(payload))
end

local function unitPrice(player, blessId)
	blessId = tonumber(blessId) or 0
	local level = player:getLevel()
	if blessId == 1 then
		if Blessings and Blessings.getPvpBlessingCost then
			return Blessings.getPvpBlessingCost(level, false)
		end
		return 2000
	end
	local enhanced = blessId >= 7
	if Blessings and Blessings.getBlessingCost then
		return Blessings.getBlessingCost(level, false, enhanced)
	end
	return enhanced and 26000 or 2000
end

local function priceTable(player)
	local prices = {}
	for id = 1, 8 do
		prices[id] = unitPrice(player, id)
	end
	return prices
end

local function missingInquisition(player)
	if not Blessings or not Blessings.getInquisitionPrice then
		local missing = 0
		for id = 2, 6 do
			if not player:hasBlessing(id) then
				missing = missing + 1
			end
		end
		local cost = (Blessings and Blessings.getBlessingCost and Blessings.getBlessingCost(player:getLevel(), false) or 2000) * missing * 1.1
		return missing, math.floor(cost)
	end
	return Blessings.getInquisitionPrice(player)
end

--- Resolve same-account bless target (defaults to controller).
local function resolveTarget(controller, nameOrGuid)
	if not controller then
		return nil, "Invalid player."
	end
	if not nameOrGuid or nameOrGuid == "" then
		return controller
	end
	local selfName = controller:getName()
	if type(nameOrGuid) == "string" and nameOrGuid:lower() == selfName:lower() then
		return controller
	end
	if TeamStore and TeamStore.resolveAccountMember then
		local target, err = TeamStore.resolveAccountMember(controller, nameOrGuid)
		if not target then
			return nil, err or "Character not found."
		end
		return target
	end
	-- Fallback without team lib: same-account check only.
	local candidate = nil
	if type(nameOrGuid) == "number" then
		candidate = Player(nameOrGuid) or (Game.getOfflinePlayer and Game.getOfflinePlayer(nameOrGuid))
	else
		local name = tostring(nameOrGuid)
		candidate = Player(name) or (Game.getOfflinePlayer and Game.getOfflinePlayer(name))
	end
	if not candidate then
		return nil, "Character not found."
	end
	if candidate:getAccountId() ~= controller:getAccountId() then
		return nil, "Character is not on your account."
	end
	return candidate
end

local function saveIfNeeded(player)
	if not player or not player.save then
		return
	end
	local live = Player(player:getName())
	if not live then
		player:save()
	end
end

local function charge(controller, price)
	price = tonumber(price) or 0
	if price <= 0 then
		return true
	end
	if not controller:removeMoneyBank(price) then
		return false, string.format("You need %d gold.", price)
	end
	return true
end

function RemoteBlessings.getAutoRebuy(player)
	if not player or not player.kv then
		return false
	end
	local v = player:kv():get(RemoteBlessingsConfig.KV_AUTO_REBUY)
	return v == true or v == 1 or v == "1"
end

function RemoteBlessings.setAutoRebuy(player, enabled)
	if not player or not player.kv then
		return
	end
	player:kv():set(RemoteBlessingsConfig.KV_AUTO_REBUY, enabled and 1 or 0)
end

local function dialogSnapshot(player)
	local blesses = {}
	local blessCount = 0
	for id = 1, 8 do
		local playerCount = 0
		local storeCount = 0
		if player.getBlessingCount then
			playerCount = tonumber(player:getBlessingCount(id)) or 0
			storeCount = tonumber(player:getBlessingCount(id, true)) or 0
		elseif player.hasBlessing and player:hasBlessing(id) then
			playerCount = 1
		end
		if id > 1 and (playerCount + storeCount) >= 1 then
			blessCount = blessCount + 1
		end
		blesses[#blesses + 1] = {
			blessBitwise = math.floor(2 ^ id),
			playerBlessCount = playerCount,
			store = storeCount,
		}
	end

	local promoted = player.isPromoted and player:isPromoted() == true
	local premium = false
	if player.isPremium then
		premium = player:isPremium() == true
	end
	local skillReduction = math.floor(8 * blessCount)
	local promotionReduction = promoted and 30 or 0
	local minReduction = skillReduction + promotionReduction
	local maxPvp = math.min(100, minReduction + 6 + (2 * blessCount))

	local equipLoss = 100
	if Blessings and Blessings.LossPercent and Blessings.LossPercent[math.min(blessCount, 8)] then
		equipLoss = Blessings.LossPercent[math.min(blessCount, 8)].item or 100
	end

	local skull = 0
	if player.getSkull then
		local s = player:getSkull()
		if s == SKULL_RED or s == SKULL_BLACK then
			skull = 1
			equipLoss = 100
		end
	end
	local aol = 0
	local neck = player.getSlotItem and player:getSlotItem(CONST_SLOT_NECKLACE)
	if neck and neck:getId() == (ITEM_AMULETOFLOSS or 3057) then
		aol = 1
		if skull == 0 then
			equipLoss = 0
		end
	end

	return {
		type = "dialog",
		name = player:getName(),
		totalBless = #blesses,
		blesses = blesses,
		premium = premium and 1 or 0,
		promotion = promoted and 1 or 0,
		pvpMinXpLoss = minReduction,
		pvpMaxXpLoss = maxPvp,
		pveExpLoss = minReduction,
		equipPvpLoss = equipLoss,
		equipPveLoss = equipLoss,
		skull = skull,
		aol = aol,
		logs = {},
	}
end

function RemoteBlessings.status(controller, nameOrGuid)
	local target, err = resolveTarget(controller, nameOrGuid)
	if not target then
		reply(controller, { type = "error", message = err or "Invalid target." })
		return
	end
	local missing, price = missingInquisition(target)
	local targetName = target:getName()
	local forSelf = targetName:lower() == controller:getName():lower()
	local message
	if missing > 0 then
		if forSelf then
			message = string.format("%d blessings missing for %d gold.", missing, price)
		else
			message = string.format("%s: %d blessings missing for %d gold.", targetName, missing, price)
		end
	else
		message = forSelf and "You have all inquisition blessings." or (targetName .. " has all inquisition blessings.")
	end
	reply(controller, {
		type = "status",
		name = targetName,
		missing = missing,
		price = price,
		autoRebuy = RemoteBlessings.getAutoRebuy(target),
		message = message,
		prices = priceTable(target),
	})
	reply(controller, dialogSnapshot(target))
end

function RemoteBlessings.buy(controller, nameOrGuid)
	local target, err = resolveTarget(controller, nameOrGuid)
	if not target then
		return false, err or "Invalid target."
	end
	local missing, price = missingInquisition(target)
	if missing <= 0 then
		return false, "Already has all inquisition blessings."
	end
	local okCharge, chargeErr = charge(controller, price)
	if not okCharge then
		return false, chargeErr
	end
	if target.addMissingBless then
		target:addMissingBless(false, false)
	else
		for id = 2, 6 do
			if not target:hasBlessing(id) then
				target:addBlessing(id, 1)
			end
		end
	end
	if target.sendBlessStatus then
		pcall(function()
			target:sendBlessStatus()
		end)
	end
	if target.getPosition then
		pcall(function()
			target:getPosition():sendMagicEffect(CONST_ME_HOLYAREA)
		end)
	end
	saveIfNeeded(target)
	local targetName = target:getName()
	if targetName:lower() == controller:getName():lower() then
		return true, string.format("Received %d blessings for %d gold.", missing, price)
	end
	return true, string.format("Bought %d blessings for %s (%d gold).", missing, targetName, price)
end

function RemoteBlessings.buyOne(controller, blessId, nameOrGuid)
	local target, err = resolveTarget(controller, nameOrGuid)
	if not target then
		return false, err or "Invalid target."
	end
	blessId = tonumber(blessId)
	if not blessId or blessId < 1 or blessId > 8 then
		return false, "Unknown blessing."
	end
	if target:hasBlessing(blessId) then
		return false, "Already has this blessing."
	end
	local price = unitPrice(target, blessId)
	local okCharge, chargeErr = charge(controller, price)
	if not okCharge then
		return false, chargeErr
	end
	target:addBlessing(blessId, 1)
	if target.sendBlessStatus then
		pcall(function()
			target:sendBlessStatus()
		end)
	end
	if target.getPosition then
		pcall(function()
			target:getPosition():sendMagicEffect(CONST_ME_HOLYAREA)
		end)
	end
	saveIfNeeded(target)
	local name = (Blessings and Blessings.All and Blessings.All[blessId] and Blessings.All[blessId].name) or ("blessing #" .. blessId)
	local targetName = target:getName()
	if targetName:lower() == controller:getName():lower() then
		return true, string.format("Received %s for %d gold.", name, price)
	end
	return true, string.format("Bought %s for %s (%d gold).", name, targetName, price)
end

function RemoteBlessings.buyAll(controller, nameOrGuid)
	local target, err = resolveTarget(controller, nameOrGuid)
	if not target then
		return false, err or "Invalid target."
	end
	-- BuyAllBlesses charges the target - for remote we charge the controller and grant missing.
	local ok, msg = RemoteBlessings.buy(controller, target:getName())
	if ok then
		-- Also try enhanced + ToF if missing (best-effort).
		for id = 1, 8 do
			if not target:hasBlessing(id) then
				local price = unitPrice(target, id)
				if charge(controller, price) then
					target:addBlessing(id, 1)
				end
			end
		end
		saveIfNeeded(target)
	end
	return ok, msg
end

function RemoteBlessings.tryAutoRebuy(player)
	if not RemoteBlessings.getAutoRebuy(player) then
		return
	end
	local missing = missingInquisition(player)
	if missing <= 0 then
		return
	end
	local ok, msg = RemoteBlessings.buy(player)
	if ok then
		player:sendTextMessage(MESSAGE_EVENT_ADVANCE, "Auto-bless: " .. (msg or "blessings restored."))
	end
end

function RemoteBlessings.handleOpcode(player, buffer)
	if type(buffer) ~= "string" then
		return
	end
	local msg = decode(buffer)
	-- Fallback string parsing when decode is unavailable.
	if type(msg) ~= "table" then
		msg = {}
		if buffer:find('"status"', 1, true) and buffer:find('"action"', 1, true) then
			msg.action = "status"
		elseif buffer:find('"buyOne"', 1, true) then
			msg.action = "buyOne"
			msg.id = tonumber(buffer:match('"id"%s*:%s*(%d+)'))
		elseif buffer:find('"buyAll"', 1, true) then
			msg.action = "buyAll"
		elseif buffer:find('"action"%s*:%s*"buy"') or buffer:find('"action":"buy"', 1, true) then
			msg.action = "buy"
		elseif buffer:find('"setAutoRebuy"', 1, true) then
			msg.action = "setAutoRebuy"
			msg.enabled = buffer:find('"enabled"%s*:%s*true') ~= nil or buffer:find('"enabled":true', 1, true) ~= nil
		else
			return
		end
		local name = buffer:match('"name"%s*:%s*"([^"]+)"') or buffer:match('"target"%s*:%s*"([^"]+)"')
		msg.name = name
	end

	local action = msg.action
	local targetName = msg.name or msg.target or msg.character

	if action == "status" then
		RemoteBlessings.status(player, targetName)
		return
	end
	if action == "buyOne" then
		local ok, text = RemoteBlessings.buyOne(player, msg.id, targetName)
		if ok then
			player:sendTextMessage(MESSAGE_EVENT_ADVANCE, text)
			reply(player, { type = "ok", message = text, name = targetName })
			RemoteBlessings.status(player, targetName)
		else
			player:sendTextMessage(MESSAGE_FAILURE, text)
			reply(player, { type = "error", message = text })
		end
		return
	end
	if action == "buyAll" then
		local ok, text = RemoteBlessings.buyAll(player, targetName)
		reply(player, { type = ok and "ok" or "error", message = text or "", name = targetName })
		if ok then
			player:sendTextMessage(MESSAGE_EVENT_ADVANCE, text)
		else
			player:sendTextMessage(MESSAGE_FAILURE, text or "Buy all failed.")
		end
		RemoteBlessings.status(player, targetName)
		return
	end
	if action == "buy" then
		local ok, text = RemoteBlessings.buy(player, targetName)
		if ok then
			player:sendTextMessage(MESSAGE_EVENT_ADVANCE, text)
			reply(player, { type = "ok", message = text, name = targetName })
			RemoteBlessings.status(player, targetName)
		else
			player:sendTextMessage(MESSAGE_FAILURE, text)
			reply(player, { type = "error", message = text })
		end
		return
	end
	if action == "setAutoRebuy" then
		local target, err = resolveTarget(player, targetName)
		if not target then
			reply(player, { type = "error", message = err or "Invalid target." })
			return
		end
		local enabled = msg.enabled and true or false
		RemoteBlessings.setAutoRebuy(target, enabled)
		saveIfNeeded(target)
		reply(player, {
			type = "ok",
			message = enabled and "Auto-rebuy enabled." or "Auto-rebuy disabled.",
			name = target:getName(),
		})
		RemoteBlessings.status(player, target:getName())
		return
	end
end
