-- Lobbies: opcode 117 (lobby) + opcode 116 (travel), lifecycle, room fixture protection.

local loginEvent = CreatureEvent("LobbyLogin")

function loginEvent.onLogin(player)
	player:registerEvent("LobbyOpcode")
	local ok, err = pcall(LobbyManager.onLogin, player)
	if not ok then
		logger.error("[Lobby] onLogin failed for {}: {}", player:getName(), err)
	end
	return true
end

loginEvent:register()

local clientReadyCallback = EventCallback("LobbyPlayerOnClientReady")

function clientReadyCallback.playerOnClientReady(player)
	LobbyProtocol.sendLobby(player)
end

clientReadyCallback:register()

local opcodeEvent = CreatureEvent("LobbyOpcode")

function opcodeEvent.onExtendedOpcode(player, opcode, buffer)
	local handler
	if opcode == LobbyConfig.OPCODE then
		handler = LobbyProtocol.handle
	elseif opcode == LobbyConfig.TRAVEL_OPCODE then
		handler = LobbyTravel.handleOpcode
	else
		return
	end
	local ok, err = pcall(handler, player, buffer)
	if not ok then
		logger.error("[Lobby] opcode {} handler failed: {}", opcode, err)
	end
end

opcodeEvent:register()

local logoutEvent = CreatureEvent("LobbyLogout")

function logoutEvent.onLogout(player)
	if Alts.getDeployment(player) then
		local ok, err = pcall(function()
			-- Controller disconnect: alts must not stay online headless.
			local session = ExpeditionManager.getSessionByPlayer(player)
			if session then
				for _, member in ipairs(ExpeditionManager.onlinePlayers(session)) do
					if member:getId() ~= player:getId() and Alts.isCompanion(member) then
						ExpeditionManager.leave(member, { silent = true, skipTeamUndeploy = true })
					end
				end
			end
			Alts.undeploy(player)
		end)
		if not ok then
			logger.error("[Lobby] logout undeploy failed for {}: {}", player:getName(), err)
		end
	end
	local ok, err = pcall(LobbyManager.onLogout, player)
	if not ok then
		logger.error("[Lobby] onLogout failed for {}: {}", player:getName(), err)
	end
	return true
end

logoutEvent:register()

local moveItemCallback = EventCallback("LobbyPlayerOnMoveItem")

function moveItemCallback.playerOnMoveItem(player, item, _count, fromPosition, toPosition)
	local aid = item and item:getActionId()
	if aid == LobbyConfig.FIXTURE_ACTION_ID or aid == LobbyConfig.LEVER_ACTION_ID then
		player:sendCancelMessage(RETURNVALUE_NOTMOVABLE)
		return false
	end
	-- Rooms are never saved: nothing may be left on the floor.
	if toPosition and toPosition.x ~= 0xFFFF and LobbyInstance.isLobbyPosition(toPosition) then
		local fromRoom = fromPosition and fromPosition.x ~= 0xFFFF and LobbyInstance.isLobbyPosition(fromPosition)
		if not fromRoom then
			player:sendTextMessage(MESSAGE_FAILURE, "You cannot drop items in the lobby room.")
			return false
		end
	end
	return true
end

moveItemCallback:register()

local startup = GlobalEvent("LobbyStartup")

function startup.onStartup()
	local ok, err = pcall(LobbyInstance.onStartup)
	if not ok then
		logger.error("[Lobby] room template failed: {}", err)
	end
	logger.info("[Lobby] ready (opcode {}, travel {})", LobbyConfig.OPCODE, LobbyConfig.TRAVEL_OPCODE)
	return true
end

startup:register()
