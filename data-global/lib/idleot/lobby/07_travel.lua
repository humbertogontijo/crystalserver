-- Lobby room travel + opcode 116 mux (recall, guild, room enter/leave, channel cancel, training).
-- client -> server: goLobby | leaveLobby | goHometown | goGuild | channelCancel | startTraining | stopTraining
--                   | listChannels | switchChannel {channel}
-- server -> client: error | trainingState | channelStart / channelComplete / channelCancelled | instanceChannels
LobbyTravel = LobbyTravel or {}

local function replyError(player, message)
	if not player then
		return
	end
	player:sendTextMessage(MESSAGE_FAILURE, tostring(message or "Travel failed."))
	IdleUtil.sendJson(player, LobbyConfig.TRAVEL_OPCODE, { type = "error", message = tostring(message or "") })
end

--- Channel into the player's lobby room. Never creates a lobby.
function LobbyTravel.requestEnter(player, opts)
	local record = LobbyStore.getForPlayer(player)
	if not record then
		return false, "You are not in a lobby."
	end
	if LobbyInstance.isInRoom(player, record) then
		return false, "You are already in the lobby room."
	end
	return InstanceTeleport.requestLobby(player, record, opts)
end

--- Channel out of the lobby room to the saved return tile.
function LobbyTravel.requestLeave(player)
	local record = LobbyStore.getForPlayer(player)
	if not LobbyInstance.roomForPlayer(player) then
		return false, "You are not in a lobby room."
	end
	if record and LobbyStart.isActive(record) then
		return false, "Your lobby is starting an expedition."
	end
	return InstanceTeleport.requestLobby(player, record, { leave = true })
end

--- Teleport-menu toggle: enter when outside, leave when inside.
--- The personal solo lobby every player gets on login does not count as a lobby here.
function LobbyTravel.toggle(player)
	if LobbyInstance.roomForPlayer(player) then
		return LobbyTravel.requestLeave(player)
	end
	local record = LobbyStore.getForPlayer(player)
	if not record or LobbyStore.isPristine(record) then
		return false, "You are not in a lobby."
	end
	return LobbyTravel.requestEnter(player)
end

local actions = {}

actions.channelCancel = function(player)
	InstanceTeleport.handleChannelCancel(player)
	return true
end

actions.goHometown = function(player)
	return InstanceTeleport.requestHometown(player)
end

actions.goGuild = function(player)
	return InstanceTeleport.requestGuild(player)
end

actions.goLobby = function(player)
	return LobbyTravel.toggle(player)
end

actions.leaveLobby = function(player)
	return LobbyTravel.requestLeave(player)
end

actions.startTraining = function(player, msg)
	return LobbyServices.startTraining(player, { skill = msg.skill, dummy = msg.dummy })
end

actions.stopTraining = function(player)
	return LobbyServices.stopTraining(player)
end

actions.listChannels = function(player)
	InstanceWorld.sendChannels(player)
	return true
end

actions.switchChannel = function(player, msg)
	return InstanceWorld.requestChannelSwitch(player, msg.channel)
end

function LobbyTravel.handleOpcode(player, buffer)
	local msg = type(buffer) == "string" and buffer ~= "" and JsonParser.decode(buffer) or nil
	if type(msg) ~= "table" then
		return
	end
	local action = actions[tostring(msg.action or "")]
	if not action then
		return
	end
	local ok, err = action(player, msg)
	if not ok then
		replyError(player, err)
	end
end
