-- Grant stock ChestUnique rewards by unique id (same items + storages as
-- quest_reward_common.lua), without requiring the player to walk to the chest.

ChestGrant = ChestGrant or {}

local function settingForUid(uid)
	uid = tonumber(uid)
	if not uid or not ChestUnique then
		return nil
	end
	return ChestUnique[uid]
end

--- Split ChestUnique ids into auto-grant rows vs pick-one groups (shared storage).
function ChestGrant.splitGrantPlan(uids)
	local auto = {}
	local byStorage = {}
	if type(uids) ~= "table" then
		return auto, {}
	end
	for _, uid in ipairs(uids) do
		local setting = settingForUid(uid)
		if not setting then
		elseif setting.storage then
			local key = tostring(setting.storage)
			local bucket = byStorage[key]
			if not bucket then
				bucket = { storage = setting.storage, uids = {} }
				byStorage[key] = bucket
			end
			bucket.uids[#bucket.uids + 1] = uid
		else
			auto[#auto + 1] = uid
		end
	end
	local choices = {}
	for _, bucket in pairs(byStorage) do
		if #bucket.uids > 1 then
			choices[#choices + 1] = bucket
		else
			for _, uid in ipairs(bucket.uids) do
				auto[#auto + 1] = uid
			end
		end
	end
	table.sort(choices, function(a, b)
		return (a.uids[1] or 0) < (b.uids[1] or 0)
	end)
	return auto, choices
end

local function isClaimed(player, setting)
	if not player or not setting then
		return true
	end
	if setting.useKV then
		if not setting.questName then
			return false
		end
		return player:questKV(setting.questName):get("completed") and true or false
	end
	local stor = setting.storage
	if not stor then
		return false
	end
	return player:getStorageValue(stor) >= 1
end

local function choiceGroupClaimed(player, group)
	if not player or not group then
		return true
	end
	local setting = settingForUid(group.uids and group.uids[1])
	return isClaimed(player, setting)
end

local function markClaimed(player, setting)
	if not player or not setting then
		return
	end
	if setting.useKV and setting.questName then
		player:questKV(setting.questName):set("completed", true)
		return
	end
	if setting.storage then
		player:setStorageValue(setting.storage, 1)
	end
end

local function canCarry(player, weight, message)
	if not player then
		return false
	end
	weight = tonumber(weight) or 0
	if weight > 0 and checkWeightAndBackpackRoom then
		return checkWeightAndBackpackRoom(player, weight, message or "You do not have enough capacity or room.")
	end
	if weight > 0 then
		if (player:getFreeCapacity() / 100) < weight then
			player:sendTextMessage(MESSAGE_EVENT_ADVANCE, (message or "Reward") .. " is too heavy.")
			return false
		end
	end
	return true
end

--- List reward rows for the journal (fixed grants only; weapon racks are separate).
function ChestGrant.listRewards(uids)
	local out = {}
	local seen = {}
	if type(uids) ~= "table" then
		return out
	end
	local auto, _ = ChestGrant.splitGrantPlan(uids)
	for _, uid in ipairs(auto) do
		local setting = settingForUid(uid)
		if setting and type(setting.reward) == "table" then
			for _, entry in ipairs(setting.reward) do
				local itemId = tonumber(entry[1]) or 0
				local count = tonumber(entry[2]) or 1
				if itemId > 0 then
					local key = tostring(itemId)
					if not seen[key] then
						seen[key] = true
						out[#out + 1] = {
							kind = "item",
							itemId = itemId,
							count = count,
							value = itemId,
						}
					end
				end
			end
		end
	end
	return out
end

--- Pick-one reward groups still unclaimed (e.g. arena weapon rack).
function ChestGrant.pendingChoices(player, uids)
	local out = {}
	if not player or type(uids) ~= "table" then
		return out
	end
	local _, choices = ChestGrant.splitGrantPlan(uids)
	for _, group in ipairs(choices) do
		if not choiceGroupClaimed(player, group) then
			local options = {}
			for _, uid in ipairs(group.uids) do
				local setting = settingForUid(uid)
				local reward = setting and setting.reward and setting.reward[1]
				local itemId = reward and tonumber(reward[1]) or 0
				if itemId > 0 then
					options[#options + 1] = {
						uid = uid,
						itemId = itemId,
						count = tonumber(reward[2]) or 1,
					}
				end
			end
			if #options > 0 then
				out[#out + 1] = {
					id = "choice",
					label = "Reward",
					options = options,
				}
			end
		end
	end
	return out
end

--- True when every uid is already claimed (shared storages count once).
function ChestGrant.allClaimed(player, uids)
	if not player or type(uids) ~= "table" or #uids == 0 then
		return false
	end
	local checked = {}
	for _, uid in ipairs(uids) do
		local setting = settingForUid(uid)
		if setting then
			local key = setting.useKV and ("kv:" .. tostring(setting.questName)) or ("st:" .. tostring(setting.storage))
			if not checked[key] then
				checked[key] = true
				if not isClaimed(player, setting) then
					return false
				end
			end
		end
	end
	return true
end

--- Grant one ChestUnique row. Skips if already claimed (shared weapon racks).
--- Returns: granted (bool), skipped (bool), err (string|nil)
function ChestGrant.grantUid(player, uid)
	local setting = settingForUid(uid)
	if not setting then
		return false, false, "Unknown chest."
	end
	if isClaimed(player, setting) then
		return false, true, nil
	end

	local weight = tonumber(setting.weight) or 0
	if setting.container then
		local message = "You have found a " .. (getItemName and getItemName(setting.container) or "bag")
		if not canCarry(player, weight, message) then
			return false, false, "Not enough capacity or room."
		end
		local container = player:addItem(setting.container, 1)
		if not container then
			return false, false, "Could not add reward container."
		end
		for _, entry in ipairs(setting.reward or {}) do
			local itemId = entry[1]
			local count = entry[2] or 1
			local added = container:addItem(itemId, count)
			if added and ItemType(itemId):isKey() and setting.keyAction then
				added:setActionId(setting.keyAction)
			end
		end
		player:sendTextMessage(
			MESSAGE_EVENT_ADVANCE,
			"You have found a " .. (getItemName and getItemName(setting.container) or "bag") .. "."
		)
		markClaimed(player, setting)
		return true, false, nil
	end

	for _, entry in ipairs(setting.reward or {}) do
		local itemId = entry[1]
		local count = entry[2] or 1
		local itemWeight = weight
		if itemWeight <= 0 and getItemWeight then
			itemWeight = getItemWeight(itemId) * count
		end
		local name = (getItemName and getItemName(itemId)) or "item"
		local message = count > 1 and ("You have found " .. count .. " " .. name) or ("You have found a " .. name)
		if not canCarry(player, itemWeight, message) then
			return false, false, "Not enough capacity or room."
		end
		local added = player:addItem(itemId, count)
		if not added then
			return false, false, "Could not add reward."
		end
		if setting.isKey and setting.storage then
			added:setActionId(setting.storage)
		end
		player:sendTextMessage(MESSAGE_EVENT_ADVANCE, message .. ".")
	end
	markClaimed(player, setting)
	return true, false, nil
end

--- Grant a list of uids. Shared-storage groups require opts.rewardUid (pick one).
--- Returns grantedCount, errors (table of strings)
function ChestGrant.grantUids(player, uids, opts)
	local granted = 0
	local errors = {}
	if not player or type(uids) ~= "table" then
		return 0, { "Invalid grant." }
	end
	opts = opts or {}
	local auto, choices = ChestGrant.splitGrantPlan(uids)

	for _, uid in ipairs(auto) do
		local ok, skipped, err = ChestGrant.grantUid(player, uid)
		if ok then
			granted = granted + 1
		elseif not skipped and err then
			errors[#errors + 1] = err
			break
		end
	end

	if #errors > 0 then
		return granted, errors
	end

	for _, group in ipairs(choices) do
		if choiceGroupClaimed(player, group) then
		else
			local pick = tonumber(opts.rewardUid)
			if not pick then
				errors[#errors + 1] = "Choose a reward."
				break
			end
			local valid = false
			for _, uid in ipairs(group.uids) do
				if uid == pick then
					valid = true
					break
				end
			end
			if not valid then
				errors[#errors + 1] = "Invalid reward choice."
				break
			end
			local ok, skipped, err = ChestGrant.grantUid(player, pick)
			if ok then
				granted = granted + 1
			elseif not skipped and err then
				errors[#errors + 1] = err
				break
			end
		end
	end

	return granted, errors
end
