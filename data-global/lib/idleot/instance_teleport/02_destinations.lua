-- Destination hops for InstanceTeleport kinds (hometown / lobby / expedition).
-- Channel timing lives in 01_core; this file arms channels and performs teleports.
-- LobbyInstance owns lobby room build/teardown; ExpeditionManager owns hunt sessions.

local TRAVEL_OPCODE = function()
	return InstanceTeleport.OPCODE
end

local EXP_OPCODE = function()
	return (ExpeditionConfig and ExpeditionConfig.OPCODE) or 113
end

local function encodeBody(payload)
	if JsonParser and JsonParser.encode then
		local ok, encoded = pcall(JsonParser.encode, payload)
		if ok and type(encoded) == "string" then
			return encoded
		end
	end
	local kind = tostring(payload.kind or "")
	local t = tostring(payload.type or "")
	if t == "channelStart" then
		return string.format(
			'{"type":"channelStart","kind":%q,"durationMs":%d,"canCancel":%s,"holdUntilReady":%s}',
			kind,
			math.floor(tonumber(payload.durationMs) or 0),
			payload.canCancel and "true" or "false",
			payload.holdUntilReady and "true" or "false"
		)
	end
	return string.format('{"type":%q,"kind":%q}', t, kind)
end

function InstanceTeleport.notifyTravel(player, payload)
	if not player or type(payload) ~= "table" then
		return
	end
	local clean = {}
	for k, v in pairs(payload) do
		if k ~= "_opcode" then
			clean[k] = v
		end
	end
	player:sendExtendedOpcode(TRAVEL_OPCODE(), encodeBody(clean))
end

function InstanceTeleport.notifyExpedition(player, payload)
	if not player or type(payload) ~= "table" then
		return
	end
	local clean = {}
	for k, v in pairs(payload) do
		if k ~= "_opcode" then
			clean[k] = v
		end
	end
	if ExpeditionProtocol and ExpeditionProtocol.send then
		ExpeditionProtocol.send(player, clean)
		return
	end
	player:sendExtendedOpcode(EXP_OPCODE(), encodeBody(clean))
end

function InstanceTeleport.handleChannelCancel(player)
	return InstanceTeleport.cancel(player)
end

local function arrivalEffectFor(kind)
	local fx = CustomEffects or {}
	if kind == InstanceTeleport.KIND_HOMETOWN then
		return fx.IT_ARRIVAL_HOMETOWN
	elseif kind == InstanceTeleport.KIND_LOBBY then
		return fx.IT_ARRIVAL_LOBBY
	elseif kind == InstanceTeleport.KIND_EXPEDITION then
		return fx.IT_ARRIVAL_EXPEDITION
	end
	return nil
end

--- Kind-tinted POI beam on the player's arrival tile, shown only inside their instance.
function InstanceTeleport.sendArrivalEffect(player, kind)
	if not player then
		return
	end
	local pos = player:getPosition()
	if not pos then
		return
	end
	local effect = arrivalEffectFor(kind) or CONST_ME_TELEPORT
	local instanceId = player.getInstanceId and player:getInstanceId() or nil
	if instanceId == nil or not Game.getSpectators then
		pos:sendMagicEffect(effect)
		return
	end
	for _, spectator in ipairs(Game.getSpectators(pos, true, true, 0, 0, 0, 0, instanceId) or {}) do
		pos:sendMagicEffect(effect, spectator)
	end
end

local function fromExpeditionSafe(player, opts)
	if opts and opts.fromExpedition then
		return true
	end
	if ExpeditionManager and ExpeditionManager.getSessionByPlayer and ExpeditionManager.getSessionByPlayer(player) then
		return false
	end
	return true
end

--- Temple recall (open world). Works from inside a lobby room too.
function InstanceTeleport.executeHometown(player, opts)
	opts = opts or {}
	if not player then
		return false, "Invalid player."
	end

	local fromExpedition = opts.fromExpedition == true
	if not fromExpedition and ExpeditionManager and ExpeditionManager.getSessionByPlayer and ExpeditionManager.getSessionByPlayer(player) then
		return false, "Leave the expedition before recalling."
	end

	local lobbyRoom = LobbyInstance and LobbyInstance.roomForPlayer and LobbyInstance.roomForPlayer(player) or nil
	if lobbyRoom and LobbyServices and LobbyServices.onLeave then
		LobbyServices.onLeave(player)
	end

	local town = player.getTown and player:getTown() or nil
	local dest = (town and town.getTemplePosition and town:getTemplePosition()) or Position(32369, 32241, 7)
	local ok = false
	if InstanceWorld and InstanceWorld.exitToOpenWorld then
		ok = InstanceWorld.exitToOpenWorld(player, dest) and true or false
	elseif InstanceWorld and InstanceWorld.travel then
		ok = InstanceWorld.travel(player, dest) and true or false
	else
		ok = player:teleportTo(dest) and true or false
	end
	if lobbyRoom then
		LobbyInstance.scheduleTeardownCheck(lobbyRoom.lobbyId)
	end
	if not ok then
		return false, "Failed to recall to hometown."
	end
	InstanceTeleport.sendArrivalEffect(player, InstanceTeleport.KIND_HOMETOWN)
	return true
end

--- Arm hometown channel (solo), or execute immediately when opts.immediate.
function InstanceTeleport.requestHometown(player, opts)
	opts = opts or {}
	if not player then
		return false, "Invalid player."
	end
	if opts.immediate == true then
		return InstanceTeleport.executeHometown(player, opts)
	end
	if not fromExpeditionSafe(player, opts) then
		return false, "Leave the expedition before recalling."
	end
	if InstanceTeleport.isPending(player) then
		return false, "Already channeling a teleport."
	end

	local forceMs = opts.forceDurationMs
	if opts.fromExpedition then
		forceMs = forceMs or InstanceTeleport.DURATION_PZ_MS
	end
	local playerId = player:getId()
	local fromExpedition = opts.fromExpedition == true
	return InstanceTeleport.begin(player, {
		kind = InstanceTeleport.KIND_HOMETOWN,
		opcode = TRAVEL_OPCODE(),
		forceDurationMs = forceMs,
		cancelPolicy = InstanceTeleport.CANCEL_INITIATOR,
		send = InstanceTeleport.notifyTravel,
		onComplete = function(memberIds)
			local p = Player(memberIds and memberIds[1] or playerId)
			if p then
				InstanceTeleport.executeHometown(p, { fromExpedition = fromExpedition })
			end
		end,
	})
end

--- Arm the lobby room enter/leave channel (always solo). `record` is the player's lobby.
--- opts.leave: leave the room (to the saved return tile); otherwise enter it.
function InstanceTeleport.requestLobby(player, record, opts)
	opts = opts or {}
	if not player or not record then
		return false, "You are not in a lobby."
	end
	if not LobbyInstance then
		return false, "Lobby rooms are unavailable."
	end
	local leaving = opts.leave == true
	if opts.immediate == true then
		if leaving then
			return LobbyInstance.leaveNow(player)
		end
		return LobbyInstance.enterNow(player, record, opts)
	end
	if not fromExpeditionSafe(player, opts) then
		return false, "Leave the expedition before going to the lobby."
	end
	if InstanceTeleport.isPending(player) then
		return false, "Already channeling a teleport."
	end
	local forceMs = opts.forceDurationMs
	if leaving or (LobbyInstance.roomForPlayer and LobbyInstance.roomForPlayer(player)) then
		forceMs = forceMs or InstanceTeleport.DURATION_PZ_MS
	end
	local playerId = player:getId()
	local lobbyId = record.id
	return InstanceTeleport.begin(player, {
		kind = InstanceTeleport.KIND_LOBBY,
		opcode = TRAVEL_OPCODE(),
		forceDurationMs = forceMs,
		cancelPolicy = InstanceTeleport.CANCEL_INITIATOR,
		send = InstanceTeleport.notifyTravel,
		onComplete = function(memberIds)
			local p = Player(memberIds and memberIds[1] or playerId)
			if not p then
				return
			end
			local ok, err
			if leaving then
				ok, err = LobbyInstance.leaveNow(p)
			else
				local live = LobbyStore.get(lobbyId)
				if not live or not LobbyStore.member(live, p:getGuid()) then
					ok, err = false, "Your lobby changed while traveling."
				else
					-- Called out of a solo run: that run ends as part of this hop.
					if opts.fromExpedition and ExpeditionManager and ExpeditionManager.getSessionByPlayer(p) then
						ExpeditionManager.leave(p, { silent = true, skipTeleport = true })
					end
					ok, err = LobbyInstance.enterNow(p, live, {})
				end
			end
			if opts.onComplete then
				pcall(opts.onComplete, p, ok, err)
			elseif not ok and err then
				p:sendTextMessage(MESSAGE_FAILURE, err)
			end
		end,
		onCancel = function(memberIds)
			if opts.onCancel then
				pcall(opts.onCancel, Player(memberIds and memberIds[1] or playerId))
			end
		end,
	})
end

--- Group/solo expedition channel. Caller supplies onComplete / onCancel (entry, switch, leave).
function InstanceTeleport.requestExpedition(opts)
	opts = opts or {}
	opts.kind = InstanceTeleport.KIND_EXPEDITION
	opts.cancelPolicy = opts.cancelPolicy or InstanceTeleport.CANCEL_ANY
	opts.opcode = opts.opcode or EXP_OPCODE()
	opts.send = opts.send or InstanceTeleport.notifyExpedition
	return InstanceTeleport.beginGroup(opts)
end

--- Solo expedition-kind channel then opts.onComplete(player). Use holdUntilReady + markReady when prep is async.
function InstanceTeleport.armSoloExpedition(player, opts)
	opts = opts or {}
	if not player then
		return false, "Invalid player."
	end
	if InstanceTeleport.isPending(player) then
		return false, "Already channeling a teleport."
	end
	local playerId = player:getId()
	return InstanceTeleport.requestExpedition({
		initiatorId = playerId,
		memberIds = { playerId },
		holdUntilReady = opts.holdUntilReady == true,
		forceDurationMs = opts.forceDurationMs,
		onComplete = function()
			local p = Player(playerId)
			if p and opts.onComplete then
				opts.onComplete(p)
			end
		end,
		onCancel = function()
			local p = Player(playerId)
			if opts.onCancel then
				opts.onCancel(p)
			end
		end,
	})
end

--- Group lobby channel (lobby Stop: expedition back to the lobby room). Caller supplies onComplete / onCancel.
function InstanceTeleport.requestLobbyGroup(opts)
	opts = opts or {}
	opts.kind = InstanceTeleport.KIND_LOBBY
	opts.cancelPolicy = opts.cancelPolicy or InstanceTeleport.CANCEL_INITIATOR
	opts.opcode = opts.opcode or EXP_OPCODE()
	opts.send = opts.send or InstanceTeleport.notifyExpedition
	return InstanceTeleport.beginGroup(opts)
end

--- Group hometown channel (team recall leave). Caller supplies onComplete / onCancel.
function InstanceTeleport.requestHometownGroup(opts)
	opts = opts or {}
	opts.kind = InstanceTeleport.KIND_HOMETOWN
	opts.cancelPolicy = opts.cancelPolicy or InstanceTeleport.CANCEL_INITIATOR
	opts.opcode = opts.opcode or EXP_OPCODE()
	opts.send = opts.send or InstanceTeleport.notifyExpedition
	return InstanceTeleport.beginGroup(opts)
end
