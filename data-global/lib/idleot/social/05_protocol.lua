SocialProtocol = SocialProtocol or {}

local function packet()
	return NetworkMessage()
end

local function finish(player, msg)
	msg:sendToPlayer(player)
	msg:delete()
end

local function addOutfit(msg, outfit)
	outfit = outfit or {}
	local lookType = tonumber(outfit.type or outfit.lookType) or 0
	msg:addU16(lookType)
	if lookType ~= 0 then
		msg:addByte(outfit.head or outfit.lookHead or 0)
		msg:addByte(outfit.body or outfit.lookBody or 0)
		msg:addByte(outfit.legs or outfit.lookLegs or 0)
		msg:addByte(outfit.feet or outfit.lookFeet or 0)
		msg:addByte(outfit.addons or outfit.lookAddons or 0)
	else
		msg:addU16(0)
	end
end

local function groupByte(group)
	if group == "close" then
		return 3
	end
	if group == "contacts" then
		return 1
	end
	return 2
end

function SocialProtocol.sendError(player, message)
	local msg = packet()
	msg:addByte(0x74)
	msg:addByte(0)
	msg:addString(tostring(message or "Social error"))
	finish(player, msg)
end

function SocialProtocol.sendFriends(player)
	local friends = FriendsStore.getFriendsWire(player)
	local msg = packet()
	msg:addByte(0x74)
	msg:addByte(2)
	msg:addU16(#friends)
	for _, friend in ipairs(friends) do
		msg:addU32(friend.guid or 0)
		msg:addString(friend.name or "")
		msg:addByte(groupByte(friend.group))
		msg:addU16(friend.level or 0)
		msg:addString(friend.vocation or "")
		msg:addByte(friend.status == "online" and 1 or 0)
		addOutfit(msg, friend.outfit)
	end
	finish(player, msg)
end

function SocialProtocol.sendInvitations(player)
	local friendInv = FriendsStore.getInvitationsWire(player)
	local msg = packet()
	msg:addByte(0x74)
	msg:addByte(3)
	local function writeList(list)
		msg:addU16(#list)
		for _, row in ipairs(list) do
			msg:addU32(row.guid or 0)
			msg:addString(row.name or "")
			msg:addU32(row.created or 0)
		end
	end
	writeList(friendInv.received or {})
	writeList(friendInv.sent or {})
	finish(player, msg)
end

function SocialProtocol.sendSearchResult(player, result)
	result = result or {}
	local characters = result.characters or {}
	local msg = packet()
	msg:addByte(0x74)
	msg:addByte(5)
	msg:addU32(result.accountId or 0)
	msg:addByte(result.online and 1 or 0)
	msg:addByte(result.premium and 1 or 0)
	msg:addU32(result.lastLogin or 0)
	msg:addU16(#characters)
	for _, character in ipairs(characters) do
		msg:addU32(character.guid or 0)
		msg:addU32(character.creatureId or 0)
		msg:addString(character.name or "")
		msg:addU16(character.level or 0)
		msg:addString(character.vocation or "")
		msg:addString(character.world or "")
		msg:addByte(character.online and 1 or 0)
		addOutfit(msg, character.outfit)
	end
	finish(player, msg)
end

function SocialProtocol.sendBlacklist(player)
	local rows = FriendsStore.load(player).blacklist or {}
	local msg = packet()
	msg:addByte(0x74)
	msg:addByte(4)
	msg:addU16(#rows)
	for _, row in ipairs(rows) do
		msg:addU32(row.guid or 0)
		msg:addString(row.name or "")
		msg:addU32(row.created or 0)
	end
	finish(player, msg)
end

function SocialProtocol.sendBadges(player)
	local hidden = FriendsStore.load(player).badgeHidden or {}
	local level = player:getLevel() or 0
	local catalog = {
		{ id = 1, name = "Adventurer", description = "Reach level 8.", icon = "", need = 8 },
		{ id = 2, name = "Explorer", description = "Reach level 20.", icon = "", need = 20 },
		{ id = 3, name = "Veteran", description = "Reach level 50.", icon = "", need = 50 },
	}
	local msg = packet()
	msg:addByte(0x74)
	msg:addByte(6)
	msg:addU16(#catalog)
	for _, badge in ipairs(catalog) do
		msg:addU32(badge.id)
		msg:addString(badge.name)
		msg:addString(badge.description)
		msg:addString(badge.icon)
		msg:addByte(level >= badge.need and 1 or 0)
		msg:addByte(hidden[tostring(badge.id)] and 0 or 1)
	end
	finish(player, msg)
end

local function defaultSettings()
	local rows = {}
	for settingType = 0, 3 do
		rows[#rows + 1] = {
			settingType = settingType,
			showCharacterInfo = true,
			showAccountInfo = true,
			allowInspect = true,
		}
	end
	return rows
end

function SocialProtocol.sendSettings(player)
	local stored = FriendsStore.load(player).settings or {}
	if #stored == 0 then
		stored = defaultSettings()
	end
	local msg = packet()
	msg:addByte(0x74)
	msg:addByte(8)
	msg:addByte(#stored)
	for _, row in ipairs(stored) do
		msg:addByte(row.settingType or 0)
		msg:addByte(row.showCharacterInfo ~= false and 1 or 0)
		msg:addByte(row.showAccountInfo ~= false and 1 or 0)
		msg:addByte(row.allowInspect ~= false and 1 or 0)
		msg:addByte(1)
		msg:addByte(1)
		msg:addByte(1)
	end
	finish(player, msg)
end

function SocialProtocol.handle(player, buffer)
	local msg = JsonParser.decode(buffer)
	if not msg or type(msg) ~= "table" then
		return
	end
	local action = msg.action

	if action == "getFriends" then
		FriendsStore.applyPendingAccepts(player)
		SocialProtocol.sendFriends(player)
		SocialProtocol.sendInvitations(player)
	elseif action == "addFriend" then
		local ok, result = FriendsStore.requestFriend(player, msg.name or msg.target)
		if not ok then
			SocialProtocol.sendError(player, result or "Failed to add friend.")
			return
		end
		SocialProtocol.sendFriends(player)
		SocialProtocol.sendInvitations(player)
		if result.online then
			local other = Player(result.targetGuid) or Player(result.targetName)
			if other then
				local notice = NetworkMessage()
				notice:addByte(0x74)
				notice:addByte(1)
				notice:sendToPlayer(other)
				notice:delete()
				SocialProtocol.sendInvitations(other)
				other:sendTextMessage(
					MESSAGE_EVENT_ADVANCE,
					string.format("%s sent you a friend request.", player:getName())
				)
			end
		end
	elseif action == "removeFriend" then
		local ok, result = FriendsStore.removeFriend(player, msg.guid or msg.name)
		if not ok then
			SocialProtocol.sendError(player, result or "Failed to remove friend.")
			return
		end
		SocialProtocol.sendFriends(player)
		if result and result.guid then
			local other = Player(result.guid) or (result.name and Player(result.name))
			if other then
				SocialProtocol.sendFriends(other)
			end
		end
	elseif action == "setFriendGroup" then
		local ok, err = FriendsStore.setFriendGroup(player, msg.guid or msg.name, msg.group)
		if not ok then
			SocialProtocol.sendError(player, err or "Failed to set group.")
			return
		end
		SocialProtocol.sendFriends(player)
	elseif action == "acceptFriend" then
		local ok, result = FriendsStore.acceptFriend(player, msg.guid or msg.name)
		if not ok then
			SocialProtocol.sendError(player, result or "Failed to accept friend.")
			return
		end
		SocialProtocol.sendFriends(player)
		SocialProtocol.sendInvitations(player)
		if result and result.guid then
			local other = Player(result.guid) or Player(result.name)
			if other then
				SocialProtocol.sendFriends(other)
				SocialProtocol.sendInvitations(other)
				other:sendTextMessage(
					MESSAGE_EVENT_ADVANCE,
					string.format("%s accepted your friend request.", player:getName())
				)
			end
		end
	elseif action == "declineFriend" then
		local ok, err = FriendsStore.declineFriend(player, msg.guid or msg.name)
		if not ok then
			SocialProtocol.sendError(player, err or "Failed to decline friend.")
			return
		end
		SocialProtocol.sendInvitations(player)
		local other = Player(msg.guid) or Player(msg.name)
		if other then
			SocialProtocol.sendInvitations(other)
		end
	elseif action == "searchCharacter" then
		local query = msg.name or msg.query or msg.target
		logger.info("[Social] searchCharacter from {} query={}", player:getName(), tostring(query))
		local ok, result = FriendsStore.searchAccount(player, query)
		if not ok then
			logger.info("[Social] searchCharacter miss: {}", tostring(result))
			SocialProtocol.sendError(player, result or "Character not found.")
			return
		end
		local n = result and result.characters and #result.characters or 0
		logger.info("[Social] searchCharacter hit chars={}", n)
		SocialProtocol.sendSearchResult(player, result)
	elseif action == "getBlacklist" then
		SocialProtocol.sendBlacklist(player)
	elseif action == "addBlacklist" then
		local data = FriendsStore.load(player)
		local guid = tonumber(msg.guid) or 0
		local name = tostring(msg.name or "")
		if guid > 0 and name ~= "" then
			local exists = false
			for _, row in ipairs(data.blacklist) do
				if row.guid == guid then
					exists = true
					break
				end
			end
			if not exists then
				data.blacklist[#data.blacklist + 1] = { guid = guid, name = name, created = os.time() }
				FriendsStore.save(player, data)
			end
		end
		SocialProtocol.sendBlacklist(player)
	elseif action == "removeBlacklist" then
		local data = FriendsStore.load(player)
		local guid = tonumber(msg.guid) or 0
		local kept = {}
		for _, row in ipairs(data.blacklist) do
			if row.guid ~= guid then
				kept[#kept + 1] = row
			end
		end
		data.blacklist = kept
		FriendsStore.save(player, data)
		SocialProtocol.sendBlacklist(player)
	elseif action == "getBadges" then
		SocialProtocol.sendBadges(player)
	elseif action == "setBadgeVisible" then
		local data = FriendsStore.load(player)
		local id = tostring(tonumber(msg.id) or 0)
		if msg.visible == false or msg.visible == 0 then
			data.badgeHidden[id] = true
		else
			data.badgeHidden[id] = nil
		end
		FriendsStore.save(player, data)
		SocialProtocol.sendBadges(player)
	elseif action == "getSettings" then
		SocialProtocol.sendSettings(player)
	elseif action == "changeSetting" then
		local data = FriendsStore.load(player)
		if #data.settings == 0 then
			data.settings = {
				{ settingType = 0, showCharacterInfo = true, showAccountInfo = true, allowInspect = true },
				{ settingType = 1, showCharacterInfo = true, showAccountInfo = true, allowInspect = true },
				{ settingType = 2, showCharacterInfo = true, showAccountInfo = true, allowInspect = true },
				{ settingType = 3, showCharacterInfo = true, showAccountInfo = true, allowInspect = true },
			}
		end
		local settingType = tonumber(msg.settingType) or 0
		local found = false
		for _, row in ipairs(data.settings) do
			if row.settingType == settingType then
				row.showCharacterInfo = msg.showCharacterInfo ~= false
				row.showAccountInfo = msg.showAccountInfo ~= false
				row.allowInspect = msg.allowInspect ~= false
				found = true
			end
		end
		if not found then
			data.settings[#data.settings + 1] = {
				settingType = settingType,
				showCharacterInfo = msg.showCharacterInfo ~= false,
				showAccountInfo = msg.showAccountInfo ~= false,
				allowInspect = msg.allowInspect ~= false,
			}
		end
		FriendsStore.save(player, data)
		SocialProtocol.sendSettings(player)
	else
		SocialProtocol.sendError(player, "Unknown social action.")
	end
end
