-- Destination hops for InstanceTeleport kinds (hometown / lobby / expedition).
-- Channel timing lives in 01_core; this file arms channels and performs teleports.
-- LobbyInstance owns lobby room build/teardown; ExpeditionManager owns hunt sessions.

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
	IdleUtil.sendJson(player, InstanceTeleport.OPCODE, clean)
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
	ExpeditionProtocol.send(player, clean)
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

local ADVENTURERS_GUILD_POS = Position(32210, 32300, 6)

--- Open-world hop shared by hometown and guild travel. Works from inside a lobby room too.
local function executeOpenWorld(player, dest)
	local lobbyRoom = LobbyInstance and LobbyInstance.roomForPlayer and LobbyInstance.roomForPlayer(player) or nil
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
	if ok then
		InstanceTeleport.sendArrivalEffect(player, InstanceTeleport.KIND_HOMETOWN)
	end
	return ok
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

	local town = player.getTown and player:getTown() or nil
	local dest = (town and town.getTemplePosition and town:getTemplePosition()) or Position(32369, 32241, 7)
	if not executeOpenWorld(player, dest) then
		return false, "Failed to recall to hometown."
	end
	return true
end

--- Adventurers' Guild hop. The guild exit portal (aid 4253) returns to the stored town temple.
function InstanceTeleport.executeGuild(player)
	if not player then
		return false, "Invalid player."
	end
	if ExpeditionManager and ExpeditionManager.getSessionByPlayer and ExpeditionManager.getSessionByPlayer(player) then
		return false, "Leave the expedition before traveling to the guild."
	end

	local town = player.getTown and player:getTown() or nil
	if town and town.getId then
		player:setStorageValue(Storage.Quest.U9_80.AdventurersGuild.Stone, town:getId())
	end
	if not executeOpenWorld(player, ADVENTURERS_GUILD_POS) then
		return false, "Failed to travel to the Adventurers' Guild."
	end
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
		opcode = InstanceTeleport.OPCODE,
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

--- Arm the Adventurers' Guild channel (solo). Same aura and cancel rules as hometown recall.
function InstanceTeleport.requestGuild(player)
	if not player then
		return false, "Invalid player."
	end
	if not fromExpeditionSafe(player) then
		return false, "Leave the expedition before traveling to the guild."
	end
	if InstanceTeleport.isPending(player) then
		return false, "Already channeling a teleport."
	end

	local playerId = player:getId()
	return InstanceTeleport.begin(player, {
		kind = InstanceTeleport.KIND_HOMETOWN,
		opcode = InstanceTeleport.OPCODE,
		cancelPolicy = InstanceTeleport.CANCEL_INITIATOR,
		send = InstanceTeleport.notifyTravel,
		onComplete = function(memberIds)
			local p = Player(memberIds and memberIds[1] or playerId)
			if not p then
				return
			end
			local ok, err = InstanceTeleport.executeGuild(p)
			if not ok and err then
				p:sendTextMessage(MESSAGE_FAILURE, err)
			end
		end,
	})
end

--- Arm the lobby room enter/leave channel (always solo). `record` is the player's lobby
--- (may be nil when leaving a room whose lobby is gone).
--- opts.leave: leave the room (to the saved return tile); otherwise enter it.
function InstanceTeleport.requestLobby(player, record, opts)
	opts = opts or {}
	if not player or (not record and opts.leave ~= true) then
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
	local lobbyId = record and record.id
	return InstanceTeleport.begin(player, {
		kind = InstanceTeleport.KIND_LOBBY,
		destination = leaving and InstanceTeleport.DEST_OPEN_WORLD or InstanceTeleport.DEST_LOBBY,
		opcode = InstanceTeleport.OPCODE,
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
				IdleSafe.call("InstanceTeleport.requestLobby.onComplete", opts.onComplete, p, ok, err)
			elseif not ok and err then
				p:sendTextMessage(MESSAGE_FAILURE, err)
			end
		end,
		onCancel = function(memberIds)
			if opts.onCancel then
				IdleSafe.call("InstanceTeleport.requestLobby.onCancel", opts.onCancel, Player(memberIds and memberIds[1] or playerId))
			end
		end,
	})
end

--- Group/solo expedition channel. Caller supplies onComplete / onCancel (entry, switch, leave).
function InstanceTeleport.requestExpedition(opts)
	opts = opts or {}
	opts.kind = InstanceTeleport.KIND_EXPEDITION
	opts.cancelPolicy = opts.cancelPolicy or InstanceTeleport.CANCEL_ANY
	opts.opcode = opts.opcode or ExpeditionConfig.OPCODE
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

--- Server-forced exit channel when a run ends (raid cleared, boss won/failed): not cancellable
--- and not blocked by PZ lock. Members already channeling their own hop are left to it.
--- Returns false when nobody could be armed; the caller then exits without a channel.
--- opts.destination: DEST_LOBBY (hunt/boss, default) or DEST_OPEN_WORLD (raid).
function InstanceTeleport.requestExpeditionExit(opts)
	opts = opts or {}
	local memberIds = {}
	for _, id in ipairs(opts.memberIds or {}) do
		local p = Player(id)
		if p and not InstanceTeleport.isPending(p) then
			memberIds[#memberIds + 1] = id
		end
	end
	if #memberIds == 0 then
		return false, "No members."
	end
	return InstanceTeleport.beginGroup({
		kind = InstanceTeleport.KIND_LOBBY,
		destination = opts.destination or InstanceTeleport.DEST_LOBBY,
		memberIds = memberIds,
		cancelPolicy = InstanceTeleport.CANCEL_NONE,
		ignoreCombatLock = true,
		forceDurationMs = opts.durationMs,
		opcode = ExpeditionConfig.OPCODE,
		send = InstanceTeleport.notifyExpedition,
		onComplete = opts.onComplete,
	})
end

--- Group lobby channel (lobby Stop: expedition back to the lobby room). Caller supplies onComplete / onCancel.
function InstanceTeleport.requestLobbyGroup(opts)
	opts = opts or {}
	opts.kind = InstanceTeleport.KIND_LOBBY
	opts.cancelPolicy = opts.cancelPolicy or InstanceTeleport.CANCEL_INITIATOR
	opts.opcode = opts.opcode or ExpeditionConfig.OPCODE
	opts.send = opts.send or InstanceTeleport.notifyExpedition
	return InstanceTeleport.beginGroup(opts)
end

--- Solo open-world channel switch cast; opts.onComplete(player) performs the switch.
--- Capped at CHANNEL_SWITCH_MAX_MS so a wild-area switch is not a full recall.
function InstanceTeleport.requestChannel(player, opts)
	opts = opts or {}
	if not player then
		return false, "Invalid player."
	end
	if InstanceTeleport.isPending(player) then
		return false, "Already channeling a teleport."
	end
	local playerId = player:getId()
	return InstanceTeleport.begin(player, {
		kind = InstanceTeleport.KIND_CHANNEL,
		destination = InstanceTeleport.DEST_OPEN_WORLD,
		opcode = InstanceTeleport.OPCODE,
		forceDurationMs = math.min(InstanceTeleport.durationMsFor(player, {}), InstanceTeleport.CHANNEL_SWITCH_MAX_MS),
		cancelPolicy = InstanceTeleport.CANCEL_INITIATOR,
		send = InstanceTeleport.notifyTravel,
		onComplete = function(memberIds)
			local p = Player(memberIds and memberIds[1] or playerId)
			if p and opts.onComplete then
				opts.onComplete(p)
			end
		end,
	})
end

--- Group hometown channel (team recall leave). Caller supplies onComplete / onCancel.
function InstanceTeleport.requestHometownGroup(opts)
	opts = opts or {}
	opts.kind = InstanceTeleport.KIND_HOMETOWN
	opts.cancelPolicy = opts.cancelPolicy or InstanceTeleport.CANCEL_INITIATOR
	opts.opcode = opts.opcode or ExpeditionConfig.OPCODE
	opts.send = opts.send or InstanceTeleport.notifyExpedition
	return InstanceTeleport.beginGroup(opts)
end
