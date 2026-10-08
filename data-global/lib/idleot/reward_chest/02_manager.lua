RewardChest = RewardChest or {}

local function decodePayload(buffer)
	local ok, decoded = pcall(JsonParser.decode, buffer)
	if ok and type(decoded) == "table" then
		return decoded
	end
	return nil
end

local function reply(player, payloadJson)
	if player then
		player:sendExtendedOpcode(RewardChestConfig.OPCODE, payloadJson)
	end
end

function RewardChest.open(player)
	if not player then
		return false
	end
	return player:openRewardChest()
end

function RewardChest.collect(player)
	if not player then
		return false
	end
	local ok = player:collectRewardChest()
	RewardChest.sendStatus(player)
	return ok
end

function RewardChest.hasLoot(player)
	if not player then
		return false
	end
	local list = player:getRewardList()
	if type(list) ~= "table" or #list == 0 then
		return false
	end
	for _, rewardId in ipairs(list) do
		local reward = player:getReward(rewardId, false)
		if reward and reward ~= false and reward.getSize then
			if (reward:getSize() or 0) > 0 then
				return true
			end
		end
	end
	return false
end

local function encodeStatus(hasLoot)
	return string.format('{"type":"status","hasLoot":%s}', hasLoot and "true" or "false")
end

function RewardChest.sendStatus(player)
	if not player then
		return
	end
	reply(player, encodeStatus(RewardChest.hasLoot(player)))
end

function RewardChest.handleOpcode(player, buffer)
	if type(buffer) ~= "string" or buffer == "" then
		return
	end

	local payload = decodePayload(buffer)
	local action = payload and payload.action
	if not action then
		action = buffer:match('"action"%s*:%s*"([^"]+)"')
	end

	if action == "open" then
		RewardChest.open(player)
	elseif action == "collect" then
		RewardChest.collect(player)
	elseif action == "status" then
		RewardChest.sendStatus(player)
	end
end
