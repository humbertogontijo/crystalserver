Letters = Letters or {}

-- Letter the player last opened, keyed by player id; claim acts on it.
local openByPlayerId = {}

local function template(key)
	return type(key) == "string" and LetterConfig.TEMPLATES[key] or nil
end

local function reply(player, payload)
	if player then
		player:sendExtendedOpcode(LetterConfig.OPCODE, JsonParser.encode(payload))
	end
end

local function sendError(player, message)
	player:sendTextMessage(MESSAGE_FAILURE, message)
	reply(player, { type = "error", message = message })
end

local function isLetter(item)
	return item and item:getId() == LetterConfig.ITEM_ID and item:getActionId() == LetterConfig.ACTION_ID
end

local function templateKeyOf(item)
	local key = item:getCustomAttribute(LetterConfig.TEMPLATE_ATTRIBUTE)
	return type(key) == "string" and key or nil
end

local function isCarriedBy(item, player)
	return item:getTopParent() == player
end

local function rewardPayload(reward)
	local items = {}
	for index, entry in ipairs(reward.items or {}) do
		local itemType = ItemType(entry.id)
		items[#items + 1] = {
			index = index,
			id = entry.id,
			name = itemType and itemType:getName() or tostring(entry.id),
			charges = entry.charges or 0,
			count = entry.count or 1,
		}
	end
	return { kind = reward.kind, items = items }
end

local function collectLetters(container, out)
	if not container then
		return
	end
	for _, item in ipairs(container:getItems(true)) do
		if isLetter(item) then
			out[#out + 1] = item
		end
	end
end

function Letters.hasUnclaimed(player)
	if not player then
		return false
	end
	local found = {}
	collectLetters(player:getStoreInbox(), found)
	local backpack = player:getSlotItem(CONST_SLOT_BACKPACK)
	if backpack and backpack:isContainer() then
		collectLetters(backpack, found)
	end
	return #found > 0
end

function Letters.sendStatus(player)
	reply(player, { type = "status", has = Letters.hasUnclaimed(player) })
end

function Letters.deliver(player, key)
	if not player or not template(key) then
		return false
	end
	local inbox = player:getStoreInbox()
	if not inbox then
		return false
	end
	local letter = inbox:addItem(LetterConfig.ITEM_ID, 1, INDEX_WHEREEVER, FLAG_NOLIMIT)
	if not letter then
		logger.error("[Letters] could not deliver '{}' to {}", key, player:getName())
		return false
	end
	letter:setActionId(LetterConfig.ACTION_ID)
	letter:setCustomAttribute(LetterConfig.TEMPLATE_ATTRIBUTE, key)
	letter:setAttribute(ITEM_ATTRIBUTE_DESCRIPTION, LetterConfig.DESCRIPTION)
	return true
end

--- Delivers each AUTO_DELIVER template this character has not received yet.
function Letters.deliverPending(player)
	local kv = player:kv():scoped(LetterConfig.KV_SCOPE):scoped("delivered")
	local delivered = 0
	for _, key in ipairs(LetterConfig.AUTO_DELIVER) do
		local tpl = template(key)
		if tpl and not kv:get(key) then
			if tpl.storage and player:getStorageValue(tpl.storage) > 0 then
				kv:set(key, true)
			elseif Letters.deliver(player, key) then
				kv:set(key, true)
				delivered = delivered + 1
			end
		end
	end
	if delivered > 0 then
		player:sendTextMessage(MESSAGE_EVENT_ADVANCE, "You have received a letter in your store inbox.")
	end
	return delivered
end

function Letters.open(player, item)
	if not player or not isLetter(item) then
		return false
	end
	local key = templateKeyOf(item)
	local tpl = template(key)
	if not tpl then
		player:sendTextMessage(MESSAGE_FAILURE, "This letter is blank.")
		return true
	end
	if not isCarriedBy(item, player) then
		player:sendTextMessage(MESSAGE_FAILURE, "Pick up the letter to read it.")
		return true
	end
	openByPlayerId[player:getId()] = { item = item, key = key }
	reply(player, {
		type = "letter",
		subject = tpl.subject,
		body = tpl.body,
		reward = rewardPayload(tpl.reward or {}),
	})
	return true
end

local function selectGrants(reward, choice)
	local items = reward.items or {}
	if reward.kind == "choice" then
		local index = tonumber(choice)
		local entry = index and items[index]
		if not entry then
			return nil, "Choose one of the rewards first."
		end
		return { entry }
	end
	return items
end

local function grantItem(inbox, entry, description)
	local item = inbox:addItem(entry.id, entry.charges or entry.count or 1, INDEX_WHEREEVER, FLAG_NOLIMIT)
	if not item then
		return nil
	end
	item:setActionId(IMMOVABLE_ACTION_ID)
	item:setAttribute(ITEM_ATTRIBUTE_STORE, systemTime())
	if description then
		item:setAttribute(ITEM_ATTRIBUTE_DESCRIPTION, description)
	end
	return item
end

function Letters.claim(player, choice)
	if not player then
		return false
	end
	local playerId = player:getId()
	local state = openByPlayerId[playerId]
	if not state then
		sendError(player, "Open the letter first.")
		return false
	end
	local letter = state.item
	if not isLetter(letter) or not isCarriedBy(letter, player) or templateKeyOf(letter) ~= state.key then
		openByPlayerId[playerId] = nil
		sendError(player, "You no longer have this letter.")
		return false
	end

	local tpl = template(state.key)
	local reward = tpl.reward or {}
	local grants, err = selectGrants(reward, choice)
	if not grants then
		sendError(player, err)
		return false
	end

	local inbox = player:getStoreInbox()
	if not inbox then
		sendError(player, "Your store inbox is not available.")
		return false
	end
	local weight = 0
	for _, entry in ipairs(grants) do
		local itemType = ItemType(entry.id)
		weight = weight + (itemType and itemType:getWeight() or 0)
	end
	local freedSlot = letter:getParent() == inbox and 1 or 0
	if #inbox:getItems() - freedSlot + #grants > inbox:getMaxCapacity() then
		sendError(player, "You need free slots in your store inbox to claim this reward.")
		return false
	end
	if player:getFreeCapacity() < weight then
		sendError(player, "You do not have enough capacity to claim this reward.")
		return false
	end

	local granted = {}
	for _, entry in ipairs(grants) do
		local item = grantItem(inbox, entry, reward.itemDescription)
		if not item then
			for _, added in ipairs(granted) do
				added:remove()
			end
			sendError(player, "Could not deliver the reward, please try again.")
			return false
		end
		granted[#granted + 1] = item
	end

	letter:remove()
	openByPlayerId[playerId] = nil
	if tpl.storage then
		player:setStorageValue(tpl.storage, 1)
	end

	local names = {}
	for _, item in ipairs(granted) do
		names[#names + 1] = item:getName()
	end
	player:sendTextMessage(MESSAGE_EVENT_ADVANCE, string.format("You received %s in your store inbox.", table.concat(names, ", ")))
	reply(player, { type = "claimed", items = names })
	Letters.sendStatus(player)
	return true
end

function Letters.forget(playerId)
	openByPlayerId[playerId] = nil
end
