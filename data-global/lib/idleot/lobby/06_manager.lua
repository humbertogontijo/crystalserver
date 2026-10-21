-- Lobby membership, invites, leadership, presence and the per-lobby team channel.
LobbyManager = LobbyManager or {}

local TEAM_CHANNEL_CLOSED = "The lobby channel has been closed."

-- target guid -> { lobbyId, fromGuid, fromName, expires }
local invitesByTarget = {}

local function online(guid)
	return Alts.findOnlinePlayerByGuid(guid)
end

local function isRealUi(player)
	return player ~= nil and Alts.isRealUiClient(player)
end

local function notify(record)
	LobbyProtocol.broadcast(record)
end

local function sendLobby(player)
	LobbyProtocol.sendLobby(player)
end

local function syncTeamFinder(record)
	if LobbyTeamFinder and LobbyTeamFinder.sync then
		LobbyTeamFinder.sync(record)
	end
end

local function unlistTeamFinder(record, closeChannel)
	if LobbyTeamFinder and LobbyTeamFinder.unlist then
		LobbyTeamFinder.unlist(record, closeChannel)
	end
end

-- Team channel ---------------------------------------------------------------

local function closeChannel(host, record)
	if not host then
		return
	end
	-- Team Finder–backed listings use the CIP closed banner (Lua default).
	if record and record.teamFinder then
		host:closeTeamChannel()
	else
		host:closeTeamChannel(TEAM_CHANNEL_CLOSED)
	end
end

function LobbyManager.channelName(record)
	-- CIP Assemble Team opens "{Name}'s Team Channel"; share that when TF-backed.
	if record and record.teamFinder then
		local host = online(record.hostGuid)
		local name = host and host:getName() or tostring(record.hostName or "")
		return name .. "'s Team Channel"
	end
	local title = tostring(record and record.title or "")
	if title == "" then
		return tostring(record and record.hostName or "") .. "'s lobby"
	end
	return title
end

-- Sent ahead of the channel packet (same stream) so the client knows not to focus the tab.
local function sendChannelHint(record, player)
	if LobbyProtocol.send then
		LobbyProtocol.send(player, { type = "lobbyChannel", name = LobbyManager.channelName(record) })
	end
end

local function inviteToChannel(host, member)
	if host and member and host:getGuid() ~= member:getGuid() and isRealUi(member) then
		local record = LobbyStore.getForPlayer(host)
		if record then
			sendChannelHint(record, member)
		end
		host:inviteToTeamChannel(member)
	end
end

local function excludeFromChannel(host, member)
	if host and member and host:getGuid() ~= member:getGuid() then
		host:excludeFromTeamChannel(member)
	end
end

--- (Re)open the lobby channel on the live host and invite online humans.
function LobbyManager.openChannel(record)
	local host = record and online(record.hostGuid) or nil
	if not host or #record.members < 2 then
		return
	end
	sendChannelHint(record, host)
	-- Empty name → CIP "{Name}'s Team Channel" when the listing is Team Finder–backed.
	if record.teamFinder then
		host:createTeamChannel()
	else
		host:createTeamChannel(LobbyManager.channelName(record))
	end
	for _, m in ipairs(record.members) do
		inviteToChannel(host, online(m.guid))
	end
end

-- Presence / state -------------------------------------------------------------

local function sessionOf(player)
	return ExpeditionManager.getSessionByPlayer(player)
end

--- inLobby | inExpedition | busy | away | offline, plus the session when hunting.
function LobbyManager.presence(record, entry)
	local p = online(entry.guid)
	if not p then
		return LobbyConfig.PRESENCE_OFFLINE
	end
	local session = sessionOf(p)
	if session then
		if session.lobbyId == record.id then
			return LobbyConfig.PRESENCE_IN_EXPEDITION, session
		end
		return LobbyConfig.PRESENCE_BUSY, session
	end
	if LobbyInstance.isInRoom(p, record) then
		return LobbyConfig.PRESENCE_IN_LOBBY
	end
	return LobbyConfig.PRESENCE_AWAY
end

function LobbyManager.state(record)
	local rt = LobbyStore.runtime(record)
	if rt.call then
		return LobbyConfig.STATE_CALLING
	end
	if rt.channeling then
		return LobbyConfig.STATE_CHANNELING
	end
	for _, m in ipairs(record.members) do
		local p = online(m.guid)
		local session = p and sessionOf(p) or nil
		if session and session.lobbyId == record.id then
			return LobbyConfig.STATE_RUNNING
		end
	end
	return LobbyConfig.STATE_LOBBY
end

function LobbyManager.isIdle(record)
	return LobbyManager.state(record) == LobbyConfig.STATE_LOBBY
end

-- Lifecycle helpers ------------------------------------------------------------

local function logoutAlt(entry)
	local p = online(entry.guid)
	if p and Alts.isCompanion(p) and not isRealUi(p) then
		Alts.safeLogoutCompanion(p)
	end
end

--- Make `entry` host. Alts of a different previous account leave the lobby.
function LobbyManager.transferHost(record, entry, reason)
	if not record or not entry or record.hostGuid == entry.guid then
		return false
	end
	local oldHostGuid = record.hostGuid
	local oldAccount = record.hostAccountId
	local oldHost = online(oldHostGuid)
	if record.teamFinder then
		unlistTeamFinder(record, false)
	end
	closeChannel(oldHost, record)
	LobbyStore.setHost(record, entry)
	local newHost = online(entry.guid)

	if entry.accountId ~= oldAccount then
		for i = #record.members, 1, -1 do
			local m = record.members[i]
			if m.accountId == oldAccount and m.guid ~= oldHostGuid and not Alts.isRealOnlineClient(m.guid) then
				table.remove(record.members, i)
				logoutAlt(m)
			end
		end
		LobbyStore.save(record)
		if oldHost and Alts.getDeployment(oldHost) then
			Alts.undeploy(oldHost)
		end
	else
		Alts.transferDeployment(oldHostGuid, entry.guid)
		if newHost then
			for _, m in ipairs(LobbyStore.alts(record)) do
				local c = online(m.guid)
				if c then
					Alts.markCompanion(c, newHost)
				end
			end
		end
	end

	if newHost then
		LobbyBonus.restoreParked(newHost, record)
	end
	LobbyManager.openChannel(record)
	logger.info("[Lobby] #{} host {} -> {} ({})", record.id, oldHostGuid, entry.guid, tostring(reason or "transfer"))
	syncTeamFinder(record)
	notify(record)
	return true
end

--- Online successor when the host leaves: same-account real client first, then any human.
local function pickSuccessor(record, allowOtherAccounts)
	local fallback = nil
	for _, m in ipairs(record.members) do
		if m.guid ~= record.hostGuid then
			local p = online(m.guid)
			if p and isRealUi(p) then
				if m.accountId == record.hostAccountId then
					return m
				end
				fallback = fallback or m
			end
		end
	end
	return allowOtherAccounts and fallback or nil
end

--- Remove a member from its lobby. Hands off leadership or dissolves an empty lobby.
local function detachMember(record, guid, opts)
	opts = opts or {}
	local entry = LobbyStore.member(record, guid)
	if not entry then
		return false
	end
	local wasHost = record.hostGuid == guid
	local p = online(guid)
	if #record.members <= 1 then
		if p then
			LobbyBonus.park(p, record)
		end
		unlistTeamFinder(record, false)
		closeChannel(p, record)
		LobbyStore.delete(record)
		return true
	end
	if wasHost then
		local successor = pickSuccessor(record, true)
		if not successor then
			for _, m in ipairs(record.members) do
				if m.guid ~= guid and not LobbyStore.isAltEntry(record, m) then
					successor = m
					break
				end
			end
		end
		if successor then
			LobbyManager.transferHost(record, successor, opts.reason or "leave")
		else
			-- Only the host's own alts remain: the lobby goes with the host.
			for _, m in ipairs(LobbyStore.alts(record)) do
				logoutAlt(m)
			end
			if p then
				LobbyBonus.park(p, record)
			end
			unlistTeamFinder(record, false)
			closeChannel(p, record)
			LobbyStore.delete(record)
			return true
		end
	end
	local host = online(record.hostGuid)
	excludeFromChannel(host, p)
	LobbyStore.removeMember(record, guid)
	if p then
		LobbyBonus.clearCombatCache(p)
	end
	LobbyStart.onMemberRemoved(record, guid)
	syncTeamFinder(record)
	notify(record)
	return true
end

--- The player's lobby, creating a private personal lobby when they have none.
function LobbyManager.ensureForPlayer(player)
	if not player then
		return nil
	end
	local record = LobbyStore.getForPlayer(player)
	if record then
		return record
	end
	record = LobbyStore.create(player, { size = LobbyConfig.MAX_MEMBERS, public = false })
	if record then
		LobbyBonus.restoreParked(player, record)
	end
	return record
end

--- Drop the player from their current lobby. Keeps them in the room if they were inside it.
local function leaveCurrent(player, reason)
	local record = LobbyStore.getForPlayer(player)
	if not record then
		return nil
	end
	local wasInRoom = LobbyInstance.isInRoom(player, record)
	detachMember(record, player:getGuid(), { reason = reason })
	return wasInRoom
end

local function moveIntoRoomIfInside(player, wasInRoom, record)
	if wasInRoom and record then
		LobbyInstance.enterNow(player, record, {})
	end
end

-- Membership actions -------------------------------------------------------------

local function checkJoinable(player, record, viaInvite)
	if not record then
		return false, "That lobby no longer exists."
	end
	if LobbyStore.member(record, player:getGuid()) then
		return false, "You are already in that lobby."
	end
	if LobbyStore.freeSlots(record) <= 0 then
		return false, "That lobby is full."
	end
	local state = LobbyManager.state(record)
	if state == LobbyConfig.STATE_CALLING or state == LobbyConfig.STATE_CHANNELING then
		return false, "That lobby is starting an expedition."
	end
	if not viaInvite then
		if not record.public then
			return false, "That lobby is private."
		end
		local level = player:getLevel()
		if level < record.levelMin or level > record.levelMax then
			return false, string.format("That lobby is for levels %d-%d.", record.levelMin, record.levelMax)
		end
	end
	return true
end

--- Find Lobby listing: joinable without an invite and not mid-expedition.
function LobbyManager.isListedFor(player, record)
	return checkJoinable(player, record, false) and LobbyManager.isIdle(record)
end

function LobbyManager.join(player, lobbyId, viaInvite)
	local record = LobbyStore.get(lobbyId)
	local ok, err = checkJoinable(player, record, viaInvite)
	if not ok then
		return false, err
	end
	local current = LobbyStore.getForPlayer(player)
	if current and LobbyStart.isActive(current) then
		return false, "Your lobby is starting an expedition."
	end
	if current and LobbyManager.state(current) == LobbyConfig.STATE_RUNNING then
		return false, "You cannot leave the lobby during an expedition."
	end
	local wasInRoom = leaveCurrent(player, "join")
	LobbyStore.addMember(record, player)
	invitesByTarget[player:getGuid()] = nil
	local host = online(record.hostGuid)
	if host then
		if #record.members == 2 then
			LobbyManager.openChannel(record)
		else
			inviteToChannel(host, player)
		end
	end
	LobbyBonus.syncCombatCache(record)
	moveIntoRoomIfInside(player, wasInRoom, record)
	syncTeamFinder(record)
	notify(record)
	return true
end

function LobbyManager.leave(player)
	local record = LobbyStore.getForPlayer(player)
	if not record then
		return false, "You are not in a lobby."
	end
	if LobbyStart.isActive(record) then
		return false, "The lobby is starting an expedition."
	end
	if LobbyManager.state(record) == LobbyConfig.STATE_RUNNING then
		return false, "You cannot leave the lobby during an expedition."
	end
	if LobbyInstance.isInRoom(player, record) then
		return false, "Leave the lobby room first."
	end
	-- Alone: the lobby dissolves (unlisting a public one) and a fresh private one replaces it.
	local wasInRoom = leaveCurrent(player, "leave")
	local personal = LobbyManager.ensureForPlayer(player)
	moveIntoRoomIfInside(player, wasInRoom, personal)
	sendLobby(player)
	return true
end

local function requireHost(player)
	local record = LobbyStore.getForPlayer(player)
	if not record then
		return nil, "You are not in a lobby."
	end
	if record.hostGuid ~= player:getGuid() then
		return nil, "Only the lobby host can do that."
	end
	return record
end

function LobbyManager.kick(host, guid)
	local record, err = requireHost(host)
	if not record then
		return false, err
	end
	guid = math.floor(tonumber(guid) or 0)
	if guid == host:getGuid() then
		return false, "You cannot kick yourself."
	end
	local entry = LobbyStore.member(record, guid)
	if not entry then
		return false, "That character is not in your lobby."
	end
	if LobbyStart.isActive(record) then
		return false, "The lobby is starting an expedition."
	end
	if LobbyManager.state(record) == LobbyConfig.STATE_RUNNING then
		return false, "You cannot kick a lobby member during an expedition."
	end
	local target = online(guid)
	local wasInRoom = target and LobbyInstance.isInRoom(target, record)
	local alt = LobbyStore.isAltEntry(record, entry)
	detachMember(record, guid, { reason = "kick" })
	if alt then
		logoutAlt(entry)
	elseif target then
		local personal = LobbyManager.ensureForPlayer(target)
		if wasInRoom then
			LobbyInstance.leaveNow(target)
		end
		target:sendTextMessage(MESSAGE_EVENT_ADVANCE, "You were removed from " .. host:getName() .. "'s lobby.")
		sendLobby(target)
		if personal then
			LobbyBonus.syncCombatCache(personal)
		end
	end
	return true
end

function LobbyManager.passLeader(host, guid)
	local record, err = requireHost(host)
	if not record then
		return false, err
	end
	local entry = LobbyStore.member(record, guid)
	if not entry or entry.guid == host:getGuid() then
		return false, "Choose another lobby member."
	end
	local target = online(entry.guid)
	if not target or not isRealUi(target) then
		return false, entry.name .. " must be online to lead the lobby."
	end
	if LobbyStart.isActive(record) then
		return false, "The lobby is starting an expedition."
	end
	LobbyManager.transferHost(record, entry, "pass")
	return true
end

function LobbyManager.update(host, opts)
	local record, err = requireHost(host)
	if not record then
		return false, err
	end
	opts = opts or {}
	local previousChannelName = LobbyManager.channelName(record)
	if opts.title ~= nil then
		record.title = LobbyStore.sanitizeTitle(opts.title, record.title)
	end
	if opts.public ~= nil then
		record.public = opts.public == true
	end
	if opts.size ~= nil then
		local size = math.floor(tonumber(opts.size) or record.size)
		record.size = math.max(#record.members, math.max(1, math.min(LobbyConfig.MAX_MEMBERS, size)))
	end
	if opts.levelMin ~= nil or opts.levelMax ~= nil then
		local lo = math.max(1, math.floor(tonumber(opts.levelMin) or record.levelMin))
		local hi = math.max(lo, math.floor(tonumber(opts.levelMax) or record.levelMax))
		record.levelMin, record.levelMax = lo, hi
	end
	if opts.expeditionId ~= nil then
		local id = tostring(opts.expeditionId or "")
		if id == "" then
			record.expeditionId, record.role, record.expeditionName, record.creatureId = "", "", "", nil
			record.bossDifficulty = nil
		else
			local catalog = ExpeditionConfig.getById(id, opts.role) or nil
			if not catalog then
				return false, "Unknown expedition."
			end
			local role = catalog.role
			if role ~= "boss" and role ~= "monster" then
				role = catalog.kind == "boss" and "boss" or "monster"
			end
			if record.expeditionId ~= tostring(catalog.id) or record.role ~= role then
				record.bossDifficulty = nil
			end
			record.expeditionId = tostring(catalog.id)
			record.role = role
			record.expeditionName = tostring(catalog.name or catalog.id)
			local cid = tonumber(catalog.creatureId)
			if (not cid or cid <= 0) and type(catalog.creatureIds) == "table" then
				cid = tonumber(catalog.creatureIds[1])
			end
			record.creatureId = cid
		end
	end
	if opts.bossDifficulty ~= nil then
		local lever = record.role == "boss"
			and ExpeditionConfig.bossDifficultyLever(ExpeditionConfig.getById(record.expeditionId, "boss"))
		if lever then
			record.bossDifficulty = BossDifficulty.normalize(lever, opts.bossDifficulty)
		else
			record.bossDifficulty = nil
		end
	end
	LobbyStore.save(record)
	if opts.expeditionId ~= nil then
		LobbyInstance.applyVariant(record)
	end
	local wasTeamFinder = record.teamFinder == true
	syncTeamFinder(record)
	if LobbyManager.channelName(record) ~= previousChannelName
		or (record.teamFinder and not wasTeamFinder)
	then
		-- Channels cannot be renamed in place: reopen under the new title / CIP TF name.
		LobbyManager.openChannel(record)
	end
	notify(record)
	return true
end

--- Invite a social friend (both online). Lands as a pending invite on the target.
function LobbyManager.invite(host, name)
	local record = LobbyStore.getForPlayer(host)
	if not record then
		return false, "You are not in a lobby."
	end
	if LobbyStore.freeSlots(record) <= 0 then
		return false, "Your lobby is full."
	end
	local target = Player(tostring(name or ""))
	if not target or not isRealUi(target) then
		return false, "That player is not online."
	end
	if target:getGuid() == host:getGuid() or LobbyStore.member(record, target:getGuid()) then
		return false, target:getName() .. " is already in your lobby."
	end
	if not (FriendsStore.isFriend(host, target:getGuid())) then
		return false, "You can only invite friends."
	end
	invitesByTarget[target:getGuid()] = {
		lobbyId = record.id,
		fromGuid = host:getGuid(),
		fromName = host:getName(),
		title = record.title,
		expires = os.time() + LobbyConfig.INVITE_TTL_SEC,
	}
	LobbyProtocol.sendInvite(target, invitesByTarget[target:getGuid()])
	target:sendTextMessage(MESSAGE_EVENT_ADVANCE, string.format("%s invited you to lobby #%d.", host:getName(), record.id))
	return true
end

function LobbyManager.pendingInvite(player)
	local invite = invitesByTarget[player:getGuid()]
	if invite and invite.expires < os.time() then
		invitesByTarget[player:getGuid()] = nil
		return nil
	end
	return invite
end

function LobbyManager.answerInvite(player, accept)
	local invite = LobbyManager.pendingInvite(player)
	invitesByTarget[player:getGuid()] = nil
	if not invite then
		return false, "That invite expired."
	end
	if not accept then
		local from = online(invite.fromGuid)
		if from then
			from:sendTextMessage(MESSAGE_EVENT_ADVANCE, player:getName() .. " declined your lobby invite.")
		end
		return true
	end
	return LobbyManager.join(player, invite.lobbyId, true)
end

--- Host adds one of their own account's characters as a alt slot.
function LobbyManager.addAlt(host, name)
	local record, err = requireHost(host)
	if not record then
		return false, err
	end
	if LobbyStore.freeSlots(record) <= 0 then
		return false, "Your lobby is full."
	end
	local alt, altErr = Alts.resolveAccountMember(host, name)
	if not alt then
		return false, altErr
	end
	if alt:getGuid() == host:getGuid() or LobbyStore.member(record, alt:getGuid()) then
		return false, alt:getName() .. " is already in your lobby."
	end
	if Alts.isRealOnlineClient(alt:getGuid()) then
		return false, alt:getName() .. " is being played; invite them instead."
	end
	local other = LobbyStore.getByGuid(alt:getGuid())
	if other then
		if not LobbyStore.isPristine(other) then
			return false, alt:getName() .. " is in another lobby."
		end
		LobbyStore.delete(other)
	end
	LobbyStore.addMember(record, alt)
	notify(record)
	return true
end

function LobbyManager.removeAlt(host, nameOrGuid)
	local record, err = requireHost(host)
	if not record then
		return false, err
	end
	local entry = nil
	for _, m in ipairs(LobbyStore.alts(record)) do
		if m.guid == tonumber(nameOrGuid) or m.name:lower() == tostring(nameOrGuid or ""):lower() then
			entry = m
		end
	end
	if not entry then
		return false, "That alt is not in your lobby."
	end
	if LobbyStart.isActive(record) then
		return false, "The lobby is starting an expedition."
	end
	LobbyStore.removeMember(record, entry.guid)
	logoutAlt(entry)
	notify(record)
	return true
end

-- Engine / login hooks ------------------------------------------------------------

--- Login: ensure a lobby, adopt a lobby whose host is offline.
function LobbyManager.onLogin(player)
	if not isRealUi(player) then
		LobbyBonus.onMemberLogin(player)
		return
	end
	local record = LobbyManager.ensureForPlayer(player)
	LobbyStore.touchMember(player)
	if record.hostGuid ~= player:getGuid() and not online(record.hostGuid) then
		local entry = LobbyStore.member(record, player:getGuid())
		if entry then
			LobbyManager.transferHost(record, entry, "login")
		end
	elseif record.hostGuid == player:getGuid() then
		LobbyManager.openChannel(record)
	else
		inviteToChannel(online(record.hostGuid), player)
	end
	LobbyBonus.onMemberLogin(player)
	syncTeamFinder(record)
	notify(record)
end

function LobbyManager.onLogout(player)
	invitesByTarget[player:getGuid()] = nil
	LobbyStart.onMemberLogout(player)
	LobbyInstance.onLogout(player)
	local record = LobbyStore.getForPlayer(player)
	if not record then
		return
	end
	if record.hostGuid == player:getGuid() then
		if LobbyStore.isPristine(record) then
			unlistTeamFinder(record, false)
			LobbyStore.delete(record)
			return
		end
		unlistTeamFinder(record, false)
		closeChannel(player, record)
		local successor = pickSuccessor(record, true)
		if successor then
			LobbyManager.transferHost(record, successor, "logout")
			return
		end
	else
		excludeFromChannel(online(record.hostGuid), player)
	end
	-- Broadcast after the creature is gone so presence reads offline.
	local lobbyId = record.id
	addEvent(function()
		local live = LobbyStore.get(lobbyId)
		if live then
			notify(live)
		end
	end, 100)
end

--- Alt switch landed on `player`: the account's lobby follows the client.
function LobbyManager.onClientAttached(player)
	local record = LobbyStore.getForPlayer(player)
	if record and record.hostGuid ~= player:getGuid() and record.hostAccountId == player:getAccountId() then
		local host = online(record.hostGuid)
		if not host or not isRealUi(host) then
			LobbyManager.transferHost(record, LobbyStore.member(record, player:getGuid()), "switch")
		end
		return
	end
	if record and not LobbyStore.isPristine(record) then
		return
	end
	-- Not in an account lobby: adopt the one hosted by a now-headless sibling, if any.
	for _, other in ipairs(Game.getAccountPlayers(player:getAccountId())) do
		if other:getGuid() ~= player:getGuid() and not isRealUi(other) then
			local theirs = LobbyStore.getForPlayer(other)
			if theirs and theirs.hostGuid == other:getGuid() and not LobbyStore.isPristine(theirs) then
				if record then
					LobbyStore.delete(record)
				end
				if not LobbyStore.member(theirs, player:getGuid()) then
					if LobbyStore.freeSlots(theirs) <= 0 then
						LobbyManager.ensureForPlayer(player)
						return
					end
					LobbyStore.addMember(theirs, player)
				end
				LobbyManager.transferHost(theirs, LobbyStore.member(theirs, player:getGuid()), "switch")
				return
			end
		end
	end
	if not record then
		LobbyManager.ensureForPlayer(player)
	end
	sendLobby(player)
end

--- A host's client detached (alt switch or disconnect): hand off to a same-account client only.
function LobbyManager.onClientDetached(player)
	local record = LobbyStore.getForPlayer(player)
	if not record or record.hostGuid ~= player:getGuid() then
		return
	end
	local successor = pickSuccessor(record, false)
	if successor then
		LobbyManager.transferHost(record, successor, "detach")
	end
end

-- Alts service hooks ------------------------------------------------------------------

Alts.companionNamesProvider = function(controller)
	local record = LobbyStore.getForPlayer(controller)
	if not record or record.hostGuid ~= controller:getGuid() then
		return {}
	end
	return LobbyStore.altNames(record)
end

Alts.controllerResolver = function(player)
	local record = LobbyStore.getForPlayer(player)
	if not record then
		return nil
	end
	return online(record.hostGuid)
end

Alts.errorSink = function(player, message)
	LobbyProtocol.sendError(player, message)
end

-- Expedition helpers ------------------------------------------------------------------

--- Online human lobby members (real clients), excluding `exceptGuid`.
function LobbyManager.onlineHumans(record, exceptGuid)
	local list = {}
	for _, m in ipairs(LobbyStore.humans(record)) do
		if m.guid ~= exceptGuid then
			local p = online(m.guid)
			if p and isRealUi(p) then
				list[#list + 1] = p
			end
		end
	end
	return list
end

function LobbyManager.isLobbyMate(a, b)
	if not a or not b then
		return false
	end
	local record = LobbyStore.getForPlayer(a)
	return record ~= nil and LobbyStore.member(record, b:getGuid()) ~= nil
end
