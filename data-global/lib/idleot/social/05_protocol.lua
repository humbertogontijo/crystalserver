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
	local listingInv = ListingsStore.getJoinInvitationsFor(player)
	local received = {}
	local sent = {}
	for _, r in ipairs(friendInv.received or {}) do
		received[#received + 1] = r
	end
	for _, r in ipairs(listingInv.received or {}) do
		received[#received + 1] = r
	end
	for _, r in ipairs(friendInv.sent or {}) do
		sent[#sent + 1] = r
	end
	for _, r in ipairs(listingInv.sent or {}) do
		sent[#sent + 1] = r
	end
	return SocialProtocol.send(player, {
		type = "invitations",
		received = received,
		sent = sent,
	})
end

function SocialProtocol.sendListings(player, filters)
	return SocialProtocol.send(player, {
		type = "listings",
		listings = ListingsStore.list(filters),
	})
end

function SocialProtocol.sendMyListing(player)
	return SocialProtocol.send(player, {
		type = "myListing",
		listing = ListingsStore.getMyListingWire(player),
	})
end

function SocialProtocol.sendSearchResult(player, result)
	return SocialProtocol.send(player, {
		type = "searchResult",
		account = result,
	})
end

local function notifyPlayer(guidOrName, payload)
	local p = nil
	if type(guidOrName) == "number" then
		p = Player(guidOrName)
	elseif type(guidOrName) == "table" then
		p = guidOrName
	else
		p = Player(tostring(guidOrName or ""))
	end
	if p then
		SocialProtocol.send(p, payload)
	end
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
	elseif action == "listListings" then
		SocialProtocol.sendListings(player, msg.filters or msg)
		SocialProtocol.sendMyListing(player)
	elseif action == "publishListing" then
		local ok, result = ListingsStore.publish(player, msg)
		if not ok then
			SocialProtocol.sendError(player, result or "Failed to publish listing.")
			return
		end
		SocialProtocol.sendMyListing(player)
		SocialProtocol.sendListings(player, {})
	elseif action == "stopListing" then
		local ok, err = ListingsStore.stop(player)
		if not ok then
			SocialProtocol.sendError(player, err or "Failed to stop listing.")
			return
		end
		SocialProtocol.sendMyListing(player)
		SocialProtocol.sendListings(player, {})
		-- Push cleared account-team roster after disassemble.
		TeamProtocol.sendTeam(player)
	elseif action == "updateListing" then
		local ok, result = ListingsStore.update(player, msg)
		if not ok then
			SocialProtocol.sendError(player, result or "Failed to update listing.")
			return
		end
		SocialProtocol.sendMyListing(player)
		SocialProtocol.sendListings(player, {})
	elseif action == "requestJoin" then
		local ok, result = ListingsStore.requestJoin(player, msg.hostGuid or msg.hostName or msg.name)
		if not ok then
			SocialProtocol.sendError(player, result or "Failed to join team.")
			return
		end
		SocialProtocol.sendMyListing(player)
		SocialProtocol.sendListings(player, {})
		SocialProtocol.sendInvitations(player)
		if result.host then
			SocialProtocol.sendMyListing(result.host)
			SocialProtocol.sendInvitations(result.host)
			SocialProtocol.sendListings(result.host, {})
			TeamProtocol.sendTeam(result.host)
			if result.accepted then
				player:sendTextMessage(MESSAGE_EVENT_ADVANCE, "You joined the team.")
				result.host:sendTextMessage(
					MESSAGE_EVENT_ADVANCE,
					string.format("%s joined your team.", player:getName())
				)
				TeamProtocol.sendTeam(player)
			end
		end
	elseif action == "setReady" then
		local ok, result = ListingsStore.setReady(player, msg.ready == true)
		if not ok then
			SocialProtocol.sendError(player, result or "Failed to update ready.")
			return
		end
		-- Push updated listing to every online accepted member (and refresh public browse).
		local hostGuid = result and result.hostGuid
		local listing = hostGuid and ListingsStore.getByHostGuid and ListingsStore.getByHostGuid(hostGuid) or nil
		local notified = {}
		local function notify(p)
			if not p or notified[p:getGuid()] then
				return
			end
			notified[p:getGuid()] = true
			SocialProtocol.sendMyListing(p)
			SocialProtocol.sendListings(p, {})
		end
		notify(player)
		if listing and type(listing.members) == "table" then
			for _, m in ipairs(listing.members) do
				if m.status == SocialConfig.MEMBER_STATUS_ACCEPTED then
					local online = Player(m.guid) or Player(m.name)
					notify(online)
				end
			end
		elseif hostGuid then
			notify(Player(hostGuid))
		end
	elseif action == "acceptJoin" then
		local ok, result = ListingsStore.acceptJoin(player, msg.guid or msg.name)
		if not ok then
			SocialProtocol.sendError(player, result or "Failed to accept join.")
			return
		end
		SocialProtocol.sendMyListing(player)
		SocialProtocol.sendInvitations(player)
		SocialProtocol.sendListings(player, {})
		TeamProtocol.sendTeam(player)
		if result.joiner then
			SocialProtocol.sendInvitations(result.joiner)
			SocialProtocol.sendListings(result.joiner, {})
			SocialProtocol.sendMyListing(result.joiner)
			result.joiner:sendTextMessage(
				MESSAGE_EVENT_ADVANCE,
				string.format("%s accepted you onto their team.", player:getName())
			)
			TeamProtocol.sendTeam(result.joiner)
		end
	elseif action == "declineJoin" then
		local ok, result = ListingsStore.declineJoin(player, msg.guid or msg.name)
		if not ok then
			SocialProtocol.sendError(player, result or "Failed to decline join.")
			return
		end
		SocialProtocol.sendMyListing(player)
		SocialProtocol.sendInvitations(player)
		SocialProtocol.sendListings(player, {})
		if result.member then
			notifyPlayer(result.member.guid, { type = "listings", listings = ListingsStore.list({}) })
			local other = Player(result.member.guid) or Player(result.member.name)
			if other then
				SocialProtocol.sendInvitations(other)
			end
		end
	elseif action == "leaveListing" then
		local ok, result = ListingsStore.leaveMember(player)
		if not ok then
			SocialProtocol.sendError(player, result or "Failed to leave team.")
			return
		end
		SocialProtocol.sendMyListing(player)
		SocialProtocol.sendListings(player, {})
		TeamProtocol.sendTeam(player)
		if result and result.listing and result.member then
			local host = Player(result.listing.hostGuid) or Player(result.listing.hostName)
			if host then
				SocialProtocol.sendMyListing(host)
				SocialProtocol.sendListings(host, {})
			end
		end
	elseif action == "kickListingMember" then
		local ok, result = ListingsStore.kickMember(player, msg.guid or msg.name)
		if not ok then
			SocialProtocol.sendError(player, result or "Failed to kick member.")
			return
		end
		SocialProtocol.sendMyListing(player)
		SocialProtocol.sendListings(player, {})
		if result.member then
			local other = Player(result.member.guid) or Player(result.member.name)
			if other then
				SocialProtocol.sendListings(other, {})
				SocialProtocol.sendInvitations(other)
				other:sendTextMessage(
					MESSAGE_EVENT_ADVANCE,
					string.format("You were removed from %s's team listing.", player:getName())
				)
			end
		end
	else
		SocialProtocol.sendError(player, "Unknown social action.")
	end
end
