TeamProtocol = TeamProtocol or {}

function TeamProtocol.send(player, payload)
	if not player then
		return false
	end
	return player:sendExtendedOpcode(TeamConfig.OPCODE, JsonParser.encode(payload))
end

function TeamProtocol.sendError(player, message)
	return TeamProtocol.send(player, {
		type = "error",
		message = tostring(message or "Team error"),
	})
end

function TeamProtocol.sendTeam(player)
	if not player or not TeamManager then
		return false
	end
	local info = TeamManager.getTeamInfo(player)
	local bonuses = nil
	local partyXp = nil
	if TeamBonus then
		bonuses = TeamBonus.getWire(player)
		partyXp = TeamBonus.computePartyXpPreview(player)
	end
	return TeamProtocol.send(player, {
		type = "team",
		members = info.members or {},
		deployed = info.deployed == true,
		maxMembers = TeamConfig.MAX_MEMBERS or 4,
		canEdit = info.canEdit == true,
		teamHostName = info.teamHostName,
		pendingRosterInvites = info.pendingRosterInvites or {},
		bonuses = bonuses,
		partyXp = partyXp,
		alts = TeamManager.getAccountAlts(player),
		altSwitch = true,
	})
end

--- Push team wire (incl. shared prey/XP bonuses) to every real online roster client.
function TeamProtocol.sendTeamToRoster(player)
	if not player then
		return false
	end
	local controller = player
	if TeamStore and TeamStore.resolveTeamController then
		controller = TeamStore.resolveTeamController(player) or player
	end
	local controllerGuid = controller.getGuid and controller:getGuid() or 0
	local seen = {}

	local function isUiClient(member)
		if not member then
			return false
		end
		local client = member.getClient and member:getClient() or nil
		local version = type(client) == "table" and tonumber(client.version) or nil
		if version and version > 0 then
			return true
		end
		-- No client protocol ⇒ headless companion (or offline stub).
		return false
	end

	local function sendTo(member)
		if not member or not member.getGuid then
			return
		end
		local guid = member:getGuid()
		if not guid or seen[guid] or not isUiClient(member) then
			return
		end
		seen[guid] = true
		TeamProtocol.sendTeam(member)
	end

	sendTo(player)
	if not (Game and Game.getPlayers) or controllerGuid <= 0 or not TeamStore or not TeamStore.resolveTeamController then
		return true
	end
	for _, online in ipairs(Game.getPlayers()) do
		if online and online:getGuid() ~= player:getGuid() then
			local theirController = TeamStore.resolveTeamController(online)
			if theirController and theirController:getGuid() == controllerGuid then
				sendTo(online)
			end
		end
	end
	return true
end

function TeamProtocol.handle(player, buffer)
	local msg = JsonParser.decode(buffer)
	if not msg or type(msg) ~= "table" then
		return
	end
	local action = msg.action
	if action == "get" or action == "list" then
		TeamProtocol.sendTeam(player)
	elseif action == "set" then
		local ok, result = TeamManager.setMembers(player, msg.members or msg.names)
		if not ok then
			TeamProtocol.sendError(player, result or "Failed to set team.")
			return
		end
		TeamProtocol.sendTeam(player)
	elseif action == "formTeam" then
		-- Alts may only deploy during expeditions; never via Manage Team.
		TeamProtocol.sendError(player, "Alts can only join you during expeditions.")
		return
	elseif action == "switchAlt" then
		local ok, err = TeamManager.switchAlt(player, msg.name)
		if not ok then
			TeamProtocol.sendError(player, err or "Failed to switch alt.")
		end
	elseif action == "inviteRosterFriend" or action == "inviteFriendToTeam" then
		local ok, result = TeamManager.inviteRosterFriend(player, msg.name or msg.friendName)
		if not ok then
			TeamProtocol.sendError(player, result or "Failed to invite friend.")
			return
		end
		TeamProtocol.sendTeam(player)
	elseif action == "passLeader" then
		local ok, result = TeamManager.passLeadership(player, msg.name or msg.targetName)
		if not ok then
			TeamProtocol.sendError(player, result or "Failed to pass leadership.")
			return
		end
		-- transferLeadership already pushes roster wire; refresh caller listing too.
		pcall(SocialProtocol.sendMyListing, player)
	elseif action == "acceptRosterInvite" then
		local ok, err = TeamManager.acceptRosterInvite(player)
		if not ok then
			TeamProtocol.sendError(player, err or "Failed to accept team invite.")
			return
		end
	elseif action == "declineRosterInvite" then
		TeamManager.declineRosterInvite(player)
	elseif action == "inviteFriends" or action == "inviteFriend" then
		if msg.members or msg.names then
			local ok, result = TeamManager.setMembers(player, msg.members or msg.names)
			if not ok then
				TeamProtocol.sendError(player, result or "Failed to set team.")
				return
			end
		end
		local ok, result = TeamManager.inviteFriends(player)
		if not ok then
			TeamProtocol.sendError(player, result or "Failed to invite friends.")
			return
		end
		TeamProtocol.send(player, {
			type = "friendsInvited",
			invited = result.invited or {},
			skipped = result.skipped or {},
		})
		TeamProtocol.sendTeam(player)
	elseif action == "buyTeamXpBoost" then
		if not TeamBonus then
			TeamProtocol.sendError(player, "Team bonuses unavailable.")
			return
		end
		local ok, err = TeamBonus.buyXpBoost(player)
		if not ok then
			TeamProtocol.sendError(player, err or "Failed to buy team XP boost.")
			return
		end
		TeamProtocol.sendTeamToRoster(player)
	elseif action == "preyAction" then
		if not TeamBonus then
			TeamProtocol.sendError(player, "Team bonuses unavailable.")
			return
		end
		local slotIndex = tonumber(msg.slot) or tonumber(msg.slotIndex) or 0
		local preyAction = tostring(msg.preyAction or msg.subaction or "")
		local ok, err = false, "Unknown prey action."
		if preyAction == "open" or preyAction == "list" then
			ok, err = TeamBonus.preyOpenSlot(player, slotIndex)
		elseif preyAction == "reroll" or preyAction == "rerollList" then
			ok, err = TeamBonus.preyRerollList(player, slotIndex)
		elseif preyAction == "select" then
			ok, err = TeamBonus.preySelect(player, slotIndex, msg.raceId)
		elseif preyAction == "bonusReroll" or preyAction == "rerollBonus" then
			ok, err = TeamBonus.preyBonusReroll(player, slotIndex)
		end
		if not ok then
			TeamProtocol.sendError(player, err or "Prey action failed.")
			return
		end
		TeamProtocol.sendTeamToRoster(player)
	else
		TeamProtocol.sendError(player, "Unknown team action.")
	end
end
