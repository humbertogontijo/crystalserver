-- Thin overlay on stock data/libs/systems/hireling.lua (do NOT full-copy core/).
-- Product deltas: deep lamp find, no duplicate lamps, register hireling if lamp add fails,
-- and HirelingsInit db.storeQuery (stock bug — also upstream-candidate).
-- Loaded after stock hireling via scripts/idleot/hireling/lamp_overlay.lua.

local function lampHirelingId(item)
	if not item or item:getId() ~= HIRELING_LAMP then
		return nil
	end
	local attr = item:getCustomAttribute("Hireling")
	if attr == nil then
		return nil
	end
	return tonumber(attr)
end

local function scanForHirelingLamp(item, hirelingId)
	if not item then
		return nil
	end
	local lampId = lampHirelingId(item)
	if lampId and lampId == hirelingId then
		return item
	end
	if item.isContainer and item:isContainer() then
		local size = item:getSize() or 0
		for i = 0, size - 1 do
			local found = scanForHirelingLamp(item:getItem(i), hirelingId)
			if found then
				return found
			end
		end
	end
	return nil
end

function Player:findHirelingLamp(hirelingId)
	hirelingId = tonumber(hirelingId)
	if not hirelingId then
		return nil
	end

	local inbox = self:getStoreInbox()
	if inbox then
		local found = scanForHirelingLamp(inbox, hirelingId)
		if found then
			return found
		end
	end

	for slot = CONST_SLOT_FIRST, CONST_SLOT_LAST do
		local found = scanForHirelingLamp(self:getSlotItem(slot), hirelingId)
		if found then
			return found
		end
	end

	return nil
end

local function checkHouseAccess(hireling)
	if not hireling or hireling.active == 0 then
		return false
	end

	local tile = hireling:getPosition():getTile()
	if not tile then
		return false
	end

	local house = tile:getHouse()
	if not house then
		return false
	end
	local player = Player(hireling:getOwnerId())
	if not player then
		player = Game.getOfflinePlayer(hireling:getOwnerId())
	end

	if house:getOwnerGuid() == hireling:getOwnerId() then
		return true
	end

	logger.debug("Returning Hireling: {} to owner '{}' Inbox", hireling:getName(), player:getName())
	if not player:findHirelingLamp(hireling:getId()) then
		local inbox = player:getStoreInbox()
		if not inbox then
			return false
		end

		local lamp = inbox:addItem(HIRELING_LAMP, 1, INDEX_WHEREEVER, FLAG_NOLIMIT)
		if lamp then
			lamp:setAttribute(ITEM_ATTRIBUTE_DESCRIPTION, "This mysterious lamp summons your very own personal hireling.\nThis item cannot be traded.\nThis magic lamp is the home of " .. hireling:getName() .. ".")
			lamp:setCustomAttribute("Hireling", hireling:getId())
		end
	end

	player:save()
	hireling.active = 0
	hireling.cid = -1
	hireling:setPosition({ x = 0, y = 0, z = 0 })
end

function Hireling:returnToLamp(player_id)
	if self.active ~= 1 then
		return
	end

	local player = Player(player_id)
	if self:getOwnerId() ~= player_id then
		player:getPosition():sendMagicEffect(CONST_ME_POFF)
		return player:sendTextMessage(MESSAGE_FAILURE, "You are not the master of this hireling.")
	end

	self.active = 0
	addEvent(function(npcId, ownerGuid, hirelingId)
		local npc = Npc(npcId)
		if not npc then
			return logger.error("[Hireling:returnToLamp] - Npc not found or is nil.")
		end

		local owner = Player(ownerGuid)
		if not owner then
			return
		end

		local lampType = ItemType(HIRELING_LAMP)
		if owner:getFreeCapacity() < lampType:getWeight(1) then
			owner:getPosition():sendMagicEffect(CONST_ME_POFF)
			return owner:sendTextMessage(MESSAGE_FAILURE, "You do not have enough capacity.")
		end

		local inbox = owner:getStoreInbox()
		local inboxItems = inbox:getItems()
		if not inbox or #inboxItems >= inbox:getMaxCapacity() then
			owner:getPosition():sendMagicEffect(CONST_ME_POFF)
			return owner:sendTextMessage(MESSAGE_FAILURE, "You don't have enough room in your inbox.")
		end

		local hireling = getHirelingById(hirelingId)
		if not hireling then
			return logger.error("[Hireling:returnToLamp] - Hireling not found or is nil for hireling name for player {}.", owner:getName())
		end

		npc:say("As you wish!", TALKTYPE_PRIVATE_NP, false, owner, npc:getPosition())
		npc:getPosition():sendMagicEffect(CONST_ME_PURPLESMOKE)
		npc:remove()
		if not owner:findHirelingLamp(hirelingId) then
			local lamp = inbox:addItem(HIRELING_LAMP, 1, INDEX_WHEREEVER, FLAG_NOLIMIT)
			if lamp then
				lamp:setAttribute(ITEM_ATTRIBUTE_DESCRIPTION, "This mysterious lamp summons your very own personal hireling.\nThis item cannot be traded.\nThis magic lamp is the home of " .. hireling:getName() .. ".")
				lamp:setCustomAttribute("Hireling", hirelingId)
			end
		end
		hireling:setPosition({ x = 0, y = 0, z = 0 })
	end, 1000, self.cid, player:getGuid(), self.id)
end

function Player:addNewHireling(name, sex)
	local hireling = Hireling:new()
	hireling.name = name
	hireling.player_id = self:getGuid()
	if sex == HIRELING_SEX.FEMALE then
		hireling.looktype = 136
		hireling.sex = HIRELING_SEX.FEMALE
	else
		hireling.looktype = 128
		hireling.sex = HIRELING_SEX.MALE
	end

	local lampType = ItemType(HIRELING_LAMP)
	if not lampType or self:getFreeCapacity() < lampType:getWeight(1) then
		self:getPosition():sendMagicEffect(CONST_ME_POFF)
		self:sendTextMessage(MESSAGE_FAILURE, "You do not have enough capacity.")
		return false
	end

	local inbox = self:getStoreInbox()
	local inboxItems = inbox:getItems()
	if not inbox or #inboxItems >= inbox:getMaxCapacity() then
		self:getPosition():sendMagicEffect(CONST_ME_POFF)
		self:sendTextMessage(MESSAGE_FAILURE, "You don't have enough room in your inbox.")
		return false
	end

	local saved = PersistHireling(hireling)
	if not saved then
		logger.error("[Player:addNewHireling] error to saving Hireling '{}' for player '{}'", name, self:getName())
		return false
	end

	local lamp = self:findHirelingLamp(hireling:getId())
	if not lamp then
		lamp = inbox:addItem(HIRELING_LAMP, 1, INDEX_WHEREEVER, FLAG_NOLIMIT)
	end
	if not lamp then
		logger.error("[Player:addNewHireling] error to add hireling lamp '{}' for player {}", name, self:getName())
		if not PLAYER_HIRELINGS[self:getGuid()] then
			PLAYER_HIRELINGS[self:getGuid()] = {}
		end
		table.insert(PLAYER_HIRELINGS[self:getGuid()], hireling)
		table.insert(HIRELINGS, hireling)
		hireling.active = 0
		return hireling
	end

	if not PLAYER_HIRELINGS[self:getGuid()] then
		PLAYER_HIRELINGS[self:getGuid()] = {}
	end
	table.insert(PLAYER_HIRELINGS[self:getGuid()], hireling)
	table.insert(HIRELINGS, hireling)

	lamp:setAttribute(ITEM_ATTRIBUTE_DESCRIPTION, "This mysterious lamp summons your very own personal hireling.\nThis item cannot be traded.\nThis magic lamp is the home of " .. hireling:getName() .. ".")
	lamp:setCustomAttribute("Hireling", hireling:getId())
	hireling.active = 0
	return hireling
end

-- Stock HirelingsInit uses `rows` without db.storeQuery — fix here + lamp-dedup on spawn.
function HirelingsInit()
	local query = string.format(
		"SELECT `ph`.* FROM `player_hirelings` AS `ph` INNER JOIN `players` as `p` ON `p`.`id` = `ph`.`player_id` WHERE `p`.`world_id` = %d",
		configManager.getNumber(configKeys.WORLD_ID)
	)
	local rows = db.storeQuery(query)
	if rows then
		local player_id, hireling
		repeat
			player_id = Result.getNumber(rows, "player_id")
			if not PLAYER_HIRELINGS[player_id] then
				PLAYER_HIRELINGS[player_id] = {}
			end

			hireling = Hireling:new()
			hireling.id = Result.getNumber(rows, "id")
			hireling.player_id = player_id
			hireling.name = Result.getString(rows, "name")
			hireling.active = Result.getNumber(rows, "active")
			hireling.sex = Result.getNumber(rows, "sex")
			hireling.posx = Result.getNumber(rows, "posx")
			hireling.posy = Result.getNumber(rows, "posy")
			hireling.posz = Result.getNumber(rows, "posz")
			hireling.lookbody = Result.getNumber(rows, "lookbody")
			hireling.lookfeet = Result.getNumber(rows, "lookfeet")
			hireling.lookhead = Result.getNumber(rows, "lookhead")
			hireling.looklegs = Result.getNumber(rows, "looklegs")
			hireling.looktype = Result.getNumber(rows, "looktype")

			table.insert(PLAYER_HIRELINGS[player_id], hireling)
			table.insert(HIRELINGS, hireling)
		until not Result.next(rows)
		Result.free(rows)

		logger.info("Spawning Hirelings")
		for i = 1, #HIRELINGS do
			if checkHouseAccess(HIRELINGS[i]) then
				HIRELINGS[i]:spawn()
			end
		end
	end
end
