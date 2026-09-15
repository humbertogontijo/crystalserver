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

function TeamProtocol.sendInventory(player, targetName, inventory)
	return TeamProtocol.send(player, {
		type = "inventory",
		name = targetName,
		inventory = inventory or {},
	})
end

local function refreshInventories(player, fromName, toName)
	if fromName then
		local inv = TeamManager.getInventorySnapshot(player, fromName)
		if inv then
			TeamProtocol.sendInventory(player, inv.name, inv)
		end
	end
	if toName and toName ~= fromName then
		local inv = TeamManager.getInventorySnapshot(player, toName)
		if inv then
			TeamProtocol.sendInventory(player, inv.name, inv)
		end
	end
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
		-- Companions may only deploy during expeditions; never via Manage Team.
		TeamProtocol.sendError(player, "Companions can only log in during expeditions.")
		return
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
		if SocialProtocol and SocialProtocol.sendMyListing then
			pcall(SocialProtocol.sendMyListing, player)
		end
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
	elseif action == "inventory" then
		local inv, err = TeamManager.getInventorySnapshot(player, msg.name or msg.guid)
		if not inv then
			TeamProtocol.sendError(player, err or "Failed to list inventory.")
			return
		end
		TeamProtocol.sendInventory(player, inv.name, inv)
	elseif action == "openContainer" then
		local cont, err = TeamManager.openContainer(player, msg)
		if not cont then
			TeamProtocol.sendError(player, err or "Failed to open container.")
			return
		end
		TeamProtocol.send(player, {
			type = "container",
			name = cont.name,
			path = cont.path,
			itemId = cont.itemId,
			label = cont.label,
			capacity = cont.capacity or cont.slots or 0,
			slots = cont.slots or cont.capacity or 0,
			items = cont.items or {},
		})
	elseif action == "openLootPouch" then
		local cont, err = TeamManager.openLootPouch(player, msg.name or msg.guid)
		if not cont then
			TeamProtocol.sendError(player, err or "Failed to open loot pouch.")
			return
		end
		TeamProtocol.send(player, {
			type = "container",
			name = cont.name,
			path = cont.path,
			itemId = cont.itemId,
			label = cont.label,
			capacity = cont.capacity or cont.slots or 0,
			slots = cont.slots or cont.capacity or 0,
			items = cont.items or {},
		})
	elseif action == "openRewardChest" then
		local cont, err = TeamManager.openRewardChest(player, msg.name or msg.guid)
		if not cont then
			TeamProtocol.sendError(player, err or "Failed to open reward chest.")
			return
		end
		-- Always forward the payload (including empty) so the client can close
		-- stale reward windows instead of error-spamming "Reward chest is empty".
		TeamProtocol.send(player, {
			type = "container",
			name = cont.name,
			path = cont.path,
			itemId = cont.itemId,
			label = cont.label,
			capacity = cont.capacity or cont.slots or 0,
			slots = cont.slots or cont.capacity or 0,
			items = cont.items or {},
		})
	elseif action == "collectRewardChest" then
		local result, err = TeamManager.collectRewardChest(player, msg.name or msg.guid)
		if not result then
			TeamProtocol.sendError(player, err or "Failed to collect reward chest.")
			return
		end
		local message
		if (result.moved or 0) <= 0 and (result.failed or 0) <= 0 then
			message = "Reward chest is empty."
		elseif (result.moved or 0) <= 0 then
			message = string.format(
				"Could not collect rewards from %s (%d items blocked).",
				result.name or "companion",
				result.failed or 0
			)
		elseif (result.failed or 0) > 0 then
			message = string.format(
				"Collected %d items from %s; %d could not be moved.",
				result.moved or 0,
				result.name or "companion",
				result.failed or 0
			)
		else
			message = string.format(
				"Collected %d items from %s into your loot pouch.",
				result.moved or 0,
				result.name or "companion"
			)
		end
		TeamProtocol.send(player, {
			type = "rewardCollected",
			ok = true,
			moved = result.moved or 0,
			failed = result.failed or 0,
			name = result.name,
			message = message,
		})
		refreshInventories(player, player:getName(), result.name)
	elseif action == "moveItem" then
		local ok, err = TeamManager.moveItem(player, msg)
		if not ok then
			TeamProtocol.sendError(player, err or "Move failed.")
			return
		end
		local fromName = msg.fromName or msg.from
		local toName = msg.toName or msg.to
		refreshInventories(player, fromName, toName)

		-- Re-send open containers so client dolls/bags update without reselecting a member.
		local function sendOpen(contName, path)
			if not contName or type(path) ~= "table" then
				return
			end
			local cont = TeamManager.openContainer(player, {
				name = contName,
				path = path,
			})
			if cont then
				TeamProtocol.send(player, {
					type = "container",
					name = cont.name,
					path = cont.path,
					itemId = cont.itemId,
					label = cont.label,
					capacity = cont.capacity or cont.slots or 0,
					slots = cont.slots or cont.capacity or 0,
					items = cont.items or {},
				})
			end
		end
		if TeamManager.containerPathsToRefresh then
			for _, path in ipairs(TeamManager.containerPathsToRefresh(msg)) do
				-- Prefer source owner for bag that held the item; toName for dest bags.
				sendOpen(fromName, path)
				if toName and toName ~= fromName then
					sendOpen(toName, path)
				end
			end
		elseif msg.containerPath and fromName then
			sendOpen(fromName, msg.containerPath)
		end
		TeamProtocol.send(player, {
			type = "moved",
			ok = true,
			fromName = fromName,
			toName = toName,
		})
	elseif action == "equip" then
		local ok, err = TeamManager.equipItem(player, msg)
		if not ok then
			TeamProtocol.sendError(player, err or "Equip failed.")
			return
		end
		local inv = TeamManager.getInventorySnapshot(player, msg.name or msg.toName)
		if inv then
			TeamProtocol.sendInventory(player, inv.name, inv)
		end
		TeamProtocol.send(player, { type = "equipped", ok = true })
	elseif action == "getAutomation" then
		local data, err = TeamManager.getAutomation(player, msg.name or msg.guid)
		if not data then
			TeamProtocol.sendError(player, err or "Failed to load automation.")
			return
		end
		TeamProtocol.send(player, {
			type = "automationConfig",
			name = data.name,
			guid = data.guid,
			level = data.level,
			vocation = data.vocation,
			autoTarget = data.autoTarget,
			ammoTypeId = data.ammoTypeId,
			loadout = data.loadout,
		})
	elseif action == "setAutomation" then
		local data, err = TeamManager.setAutomation(player, msg)
		if not data then
			TeamProtocol.sendError(player, err or "Failed to save automation.")
			return
		end
		TeamProtocol.send(player, {
			type = "automationConfig",
			name = data.name,
			guid = data.guid,
			level = data.level,
			vocation = data.vocation,
			autoTarget = data.autoTarget,
			ammoTypeId = data.ammoTypeId,
			loadout = data.loadout,
		})
	elseif action == "openWheel" then
		local data, err = TeamManager.openWheel(player, msg.name or msg.guid)
		if not data then
			TeamProtocol.sendError(player, err or "Failed to open Wheel of Destiny.")
			return
		end
		TeamProtocol.send(player, {
			type = "wheelOpen",
			name = data.name,
			guid = data.guid,
			creatureId = data.creatureId,
		})
	elseif action == "openPrey" then
		local data, err = TeamManager.openPrey(player, msg.name or msg.guid)
		if not data then
			TeamProtocol.sendError(player, err or "Failed to open Prey.")
			return
		end
		TeamProtocol.send(player, {
			type = "featureOpen",
			feature = "prey",
			name = data.name,
			guid = data.guid,
		})
	elseif action == "openForge" then
		local data, err = TeamManager.openForge(player, msg.name or msg.guid)
		if not data then
			TeamProtocol.sendError(player, err or "Failed to open Exaltation Forge.")
			return
		end
		TeamProtocol.send(player, {
			type = "featureOpen",
			feature = "forge",
			name = data.name,
			guid = data.guid,
		})
	elseif action == "openProficiency" then
		local data, err = TeamManager.openProficiency(player, msg.name or msg.guid)
		if not data then
			TeamProtocol.sendError(player, err or "Failed to open Weapon Proficiency.")
			return
		end
		TeamProtocol.send(player, {
			type = "featureOpen",
			feature = "proficiency",
			name = data.name,
			guid = data.guid,
		})
	elseif action == "openRewardWall" then
		local data, err = TeamManager.openRewardWall(player, msg.name or msg.guid)
		if not data then
			TeamProtocol.sendError(player, err or "Failed to open Reward Wall.")
			return
		end
		TeamProtocol.send(player, {
			type = "featureOpen",
			feature = "rewardWall",
			name = data.name,
			guid = data.guid,
		})
	elseif action == "openTaskBoard" then
		local data, err = TeamManager.openTaskBoard(player, msg.name or msg.guid)
		if not data then
			TeamProtocol.sendError(player, err or "Failed to open Task Board.")
			return
		end
		TeamProtocol.send(player, {
			type = "featureOpen",
			feature = "taskBoard",
			name = data.name,
			guid = data.guid,
		})
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
