-- Lobby wire + extended opcode 117.
-- client -> server: get, create, update, browse, join, leave, kick, passLeader, invite,
--   answerInvite, addAlt, removeAlt, start, answerCall, enterRoom, leaveRoom,
--   preyAction, cancelStart, switchAlt, alts (lobby XP boost is a store offer: lib/idleot/store)
-- server -> client: lobby, lobbies, invite, inviteCleared, call, callCleared, alts, error
LobbyProtocol = LobbyProtocol or {}

LobbyProtocol.send = IdleUtil.jsonSender(LobbyConfig.OPCODE)

function LobbyProtocol.sendError(player, message)
	return LobbyProtocol.send(player, { type = "error", message = tostring(message or "Lobby error.") })
end

local function memberWire(record, entry)
	local p = Alts.findOnlinePlayerByGuid(entry.guid)
	local level, vocation, outfit = entry.level, entry.vocation, entry.outfit
	if p then
		local profile = Alts.memberProfile(p)
		level, vocation, outfit = profile.level, profile.vocation, profile.outfit or outfit
	end
	local presence, session = LobbyManager.presence(record, entry)
	local row = {
		guid = entry.guid,
		name = entry.name,
		level = level or 0,
		vocation = vocation or "",
		outfit = outfit,
		kind = LobbyStore.isAltEntry(record, entry) and LobbyConfig.KIND_ALT or LobbyConfig.KIND_HUMAN,
		presence = presence,
		isLeader = entry.guid == record.hostGuid,
		online = p ~= nil,
	}
	if session then
		row.busy = {
			kind = session.role or session.kind,
			expeditionName = session.catalog and session.catalog.name or "",
		}
	end
	return row
end

--- Full lobby for one viewer (bonuses and edit rights are viewer-specific).
function LobbyProtocol.lobbyWire(record, viewer)
	local members = {}
	for _, m in ipairs(record.members) do
		members[#members + 1] = memberWire(record, m)
	end
	local rt = LobbyStore.runtime(record)
	local call = nil
	if rt.call then
		local pending = {}
		for guid, name in pairs(rt.call.pending or {}) do
			pending[#pending + 1] = { guid = guid, name = name }
		end
		call = { deadline = rt.call.deadline, remaining = math.max(0, rt.call.deadline - os.time()), pending = pending }
	end
	local room = LobbyInstance.getRoom(record)
	local difficultyLever = record.role == "boss"
		and ExpeditionConfig.bossDifficultyLever(ExpeditionConfig.getById(record.expeditionId, "boss"))
	local bossUnavailable = record.role == "boss"
		and ExpeditionConfig.availabilityLabel(ExpeditionConfig.getById(record.expeditionId, "boss"))
		or nil
	local bossCooldown = nil
	local cooldownSec, blockerName = LobbyStart.bossCooldown(record)
	if cooldownSec > 0 then
		bossCooldown = { remaining = cooldownSec, name = blockerName }
	end
	return {
		type = "lobby",
		id = record.id,
		title = record.title,
		hostGuid = record.hostGuid,
		hostName = record.hostName,
		isHost = viewer ~= nil and viewer:getGuid() == record.hostGuid,
		size = record.size,
		maxMembers = LobbyConfig.MAX_MEMBERS,
		freeSlots = LobbyStore.freeSlots(record),
		public = record.public,
		expeditionId = record.expeditionId,
		role = record.role,
		expeditionName = record.expeditionName,
		creatureId = record.creatureId,
		levelMin = record.levelMin,
		levelMax = record.levelMax,
		bossDifficulty = difficultyLever and (record.bossDifficulty or 0) or nil,
		bossDifficultyMax = difficultyLever and BossDifficulty.max(difficultyLever) or nil,
		bossCooldown = bossCooldown,
		bossUnavailable = bossUnavailable,
		leverRoom = LobbyVariants.hasLeverRoom(record),
		state = LobbyManager.state(record),
		members = members,
		call = call,
		inRoom = viewer ~= nil and LobbyInstance.isInRoom(viewer, record),
		roomOpen = room ~= nil,
		bonuses = viewer and LobbyBonus.getWire(viewer, record) or nil,
		partyXp = LobbyBonus.computePartyXpPreview(record),
		invite = viewer and LobbyManager.pendingInvite(viewer) or nil,
	}
end

function LobbyProtocol.sendLobby(player)
	if not player or not Alts.isRealUiClient(player) then
		return false
	end
	local record = LobbyStore.getForPlayer(player)
	if not record then
		return false
	end
	return LobbyProtocol.send(player, LobbyProtocol.lobbyWire(record, player))
end

--- Push the lobby to every online member with a client.
function LobbyProtocol.broadcast(record)
	if not record then
		return
	end
	for _, m in ipairs(record.members) do
		local p = Alts.findOnlinePlayerByGuid(m.guid)
		if p and Alts.isRealUiClient(p) and LobbyStore.getForPlayer(p) == record then
			LobbyProtocol.send(p, LobbyProtocol.lobbyWire(record, p))
		end
	end
end

local function browseCard(record)
	local members = {}
	for _, m in ipairs(record.members) do
		members[#members + 1] = { name = m.name, level = m.level, vocation = m.vocation, outfit = m.outfit }
	end
	local state = LobbyManager.state(record)
	return {
		id = record.id,
		title = record.title,
		hostName = record.hostName,
		expeditionId = record.expeditionId,
		expeditionName = record.expeditionName,
		role = record.role,
		creatureId = record.creatureId,
		levelMin = record.levelMin,
		levelMax = record.levelMax,
		size = record.size,
		memberCount = #record.members,
		members = members,
		state = state,
		full = LobbyStore.freeSlots(record) <= 0,
	}
end

function LobbyProtocol.sendLobbies(player, filters)
	filters = type(filters) == "table" and filters or {}
	local role = tostring(filters.role or "all")
	local search = tostring(filters.search or ""):lower()
	local cards = {}
	for _, record in ipairs(LobbyStore.all()) do
		local matches = LobbyManager.isListedFor(player, record)
		if matches and role ~= "all" and role ~= "" then
			matches = record.role == role
		end
		if matches and search ~= "" then
			local hay = (record.title .. " " .. record.hostName .. " " .. record.expeditionName):lower()
			matches = hay:find(search, 1, true) ~= nil
		end
		if matches and not Alts.findOnlinePlayerByGuid(record.hostGuid) then
			matches = false
		end
		if matches then
			cards[#cards + 1] = browseCard(record)
		end
	end
	return LobbyProtocol.send(player, { type = "lobbies", lobbies = cards })
end

function LobbyProtocol.sendInvite(player, invite)
	return LobbyProtocol.send(player, {
		type = "invite",
		lobbyId = invite.lobbyId,
		fromName = invite.fromName,
		title = invite.title,
		expires = invite.expires,
	})
end

function LobbyProtocol.sendAlts(player)
	return LobbyProtocol.send(player, { type = "alts", alts = Alts.getAccountAlts(player) })
end

local function reply(player, ok, err, refresh)
	if not ok then
		LobbyProtocol.sendError(player, err or "Lobby action failed.")
		return
	end
	if refresh ~= false then
		LobbyProtocol.sendLobby(player)
	end
end

local function handlePrey(player, msg)
	local slot = tonumber(msg.slot) or tonumber(msg.slotIndex) or 0
	local action = tostring(msg.preyAction or msg.subaction or "")
	if action == "open" or action == "list" then
		return LobbyBonus.preyOpenSlot(player, slot)
	elseif action == "reroll" or action == "rerollList" then
		return LobbyBonus.preyRerollList(player, slot)
	elseif action == "select" then
		return LobbyBonus.preySelect(player, slot, msg.raceId)
	elseif action == "bonusReroll" or action == "rerollBonus" then
		return LobbyBonus.preyBonusReroll(player, slot)
	end
	return false, "Unknown prey action."
end

local handlers = {}

handlers.get = function(player)
	LobbyManager.ensureForPlayer(player)
	LobbyProtocol.sendLobby(player)
end

handlers.create = function(player, msg)
	local record = LobbyStore.getForPlayer(player)
	if record and record.hostGuid ~= player:getGuid() then
		local ok, err = LobbyManager.leave(player)
		if not ok then
			return reply(player, false, err)
		end
	end
	LobbyManager.ensureForPlayer(player)
	reply(player, LobbyManager.update(player, {
		title = msg.title,
		size = msg.size,
		public = msg.public ~= false,
		levelMin = msg.levelMin,
		levelMax = msg.levelMax,
	}))
end

handlers.update = function(player, msg)
	local ok, err = LobbyManager.update(player, msg)
	reply(player, ok, err, false)
end

handlers.browse = function(player, msg)
	LobbyProtocol.sendLobbies(player, msg.filters or msg)
end

handlers.join = function(player, msg)
	reply(player, LobbyManager.join(player, msg.lobbyId or msg.id, false))
end

handlers.leave = function(player)
	local ok, err = LobbyManager.leave(player)
	reply(player, ok, err, false)
end

handlers.kick = function(player, msg)
	local ok, err = LobbyManager.kick(player, msg.guid)
	reply(player, ok, err, false)
end

handlers.passLeader = function(player, msg)
	local ok, err = LobbyManager.passLeader(player, msg.guid)
	reply(player, ok, err, false)
end

handlers.invite = function(player, msg)
	local ok, err = LobbyManager.invite(player, msg.name)
	if ok then
		player:sendTextMessage(MESSAGE_EVENT_ADVANCE, "Lobby invite sent to " .. tostring(msg.name) .. ".")
	end
	reply(player, ok, err, false)
end

handlers.answerInvite = function(player, msg)
	local ok, err = LobbyManager.answerInvite(player, msg.accept == true)
	LobbyProtocol.send(player, { type = "inviteCleared" })
	reply(player, ok, err)
end

handlers.addAlt = function(player, msg)
	local ok, err = LobbyManager.addAlt(player, msg.name)
	reply(player, ok, err, false)
end

handlers.removeAlt = function(player, msg)
	local ok, err = LobbyManager.removeAlt(player, msg.name or msg.guid)
	reply(player, ok, err, false)
end

handlers.start = function(player, msg)
	local record = LobbyStore.getForPlayer(player)
	if record and LobbyVariants.hasLeverRoom(record) then
		return reply(player, false, "Pull the boss lever in the lobby room to start.")
	end
	local ok, err = LobbyStart.request(player, msg)
	if not ok and not err then
		return
	end
	reply(player, ok, err, false)
end

handlers.answerCall = function(player, msg)
	local ok, err = LobbyStart.answerCall(player, msg.accept == true)
	reply(player, ok, err, false)
end

handlers.cancelStart = function(player)
	local ok, err = LobbyStart.hostCancel(player)
	reply(player, ok, err, false)
end

handlers.enterRoom = function(player)
	local ok, err = LobbyTravel.requestEnter(player)
	reply(player, ok, err, false)
end

handlers.leaveRoom = function(player)
	local ok, err = LobbyTravel.requestLeave(player)
	reply(player, ok, err, false)
end

handlers.preyAction = function(player, msg)
	local ok, err = handlePrey(player, msg)
	if ok then
		LobbyProtocol.broadcast(LobbyStore.getForPlayer(player))
	end
	reply(player, ok, err, false)
end

-- Legacy JSON path (opcode 117). Preferred: client C 0x0D → Game.playerRequestCharacterSwitch.
handlers.switchAlt = function(player, msg)
	local ok, err = Alts.switchAlt(player, msg.name)
	reply(player, ok, err, false)
end

handlers.alts = function(player)
	LobbyProtocol.sendAlts(player)
end

function LobbyProtocol.handle(player, buffer)
	local msg = JsonParser.decode(buffer)
	if type(msg) ~= "table" then
		return
	end
	local handler = handlers[tostring(msg.action or "")]
	if not handler then
		LobbyProtocol.sendError(player, "Unknown lobby action.")
		return
	end
	handler(player, msg)
end
