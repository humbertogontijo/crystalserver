SocialProtocol = SocialProtocol or {}

function SocialProtocol.send(player, payload)
	if not player then
		return false
	end
	return player:sendExtendedOpcode(SocialConfig.OPCODE, JsonParser.encode(payload))
end

function SocialProtocol.sendError(player, message)
	return SocialProtocol.send(player, {
		type = "error",
		message = tostring(message or "Social error"),
	})
end

function SocialProtocol.sendFriends(player)
	return SocialProtocol.send(player, {
		type = "friends",
		friends = FriendsStore.getFriendsWire(player),
	})
end

function SocialProtocol.sendInvitations(player)
	local friendInv = FriendsStore.getInvitationsWire(player)
	return SocialProtocol.send(player, {
		type = "invitations",
		received = friendInv.received or {},
		sent = friendInv.sent or {},
	})
end

function SocialProtocol.sendSearchResult(player, result)
	return SocialProtocol.send(player, {
		type = "searchResult",
		account = result,
	})
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
	else
		SocialProtocol.sendError(player, "Unknown social action.")
	end
end
