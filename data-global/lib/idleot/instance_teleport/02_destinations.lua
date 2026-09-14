-- Destination hops for InstanceTeleport kinds (hometown / home / expedition).
-- Channel timing lives in 01_core; this file arms channels and performs teleports.
-- PlayerHomeManager owns home *instance* build/teardown; ExpeditionManager owns hunt sessions.

local HOME_OPCODE = function()
	return (PlayerHomeConfig and PlayerHomeConfig.OPCODE) or 116
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

function InstanceTeleport.notifyHome(player, payload)
	if not player or type(payload) ~= "table" then
		return
	end
	local clean = {}
	for k, v in pairs(payload) do
		if k ~= "_opcode" then
			clean[k] = v
		end
	end
	player:sendExtendedOpcode(HOME_OPCODE(), encodeBody(clean))
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

local function fromExpeditionSafe(player, opts)
	if opts and opts.fromExpedition then
		return true
	end
	if ExpeditionManager and ExpeditionManager.getSessionByPlayer and ExpeditionManager.getSessionByPlayer(player) then
		return false
	end
	return true
end

--- Temple recall (open world). Leaves personal home session in place if needed.
function InstanceTeleport.executeHometown(player, opts)
	opts = opts or {}
	if not player then
		return false, "Invalid player."
	end

	local fromExpedition = opts.fromExpedition == true
	if not fromExpedition and ExpeditionManager and ExpeditionManager.getSessionByPlayer and ExpeditionManager.getSessionByPlayer(player) then
		return false, "Leave the expedition before recalling."
	end

	if PlayerHomeManager and PlayerHomeManager.isPlayerInHome and PlayerHomeManager.isPlayerInHome(player) then
		if PlayerHomeManager.closeHomeSession then
			PlayerHomeManager.closeHomeSession(player)
		elseif PlayerHomeManager.leaveHome then
			-- Fallback: leaveHome travels to return pos; temple hop below overrides.
			PlayerHomeManager.leaveHome(player)
		end
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
	if not ok then
		return false, "Failed to recall to hometown."
	end
	if dest and dest.sendMagicEffect then
		dest:sendMagicEffect(CONST_ME_TELEPORT)
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
		opcode = HOME_OPCODE(),
		forceDurationMs = forceMs,
		cancelPolicy = InstanceTeleport.CANCEL_INITIATOR,
		send = InstanceTeleport.notifyHome,
		onComplete = function(memberIds)
			local p = Player(memberIds and memberIds[1] or playerId)
			if p then
				InstanceTeleport.executeHometown(p, { fromExpedition = fromExpedition })
			end
		end,
	})
end

--- Arm home enter/leave channel (always solo). Destination via PlayerHomeManager.
function InstanceTeleport.requestHome(player, opts)
	opts = opts or {}
	if not player then
		return false, "Invalid player."
	end
	if not PlayerHomeManager then
		return false, "Home is unavailable."
	end
	if opts.immediate == true then
		if PlayerHomeManager.isPlayerInHome and PlayerHomeManager.isPlayerInHome(player) then
			return PlayerHomeManager.leaveHome(player)
		end
		return PlayerHomeManager.enterHome(player, opts)
	end
	if not fromExpeditionSafe(player, opts) then
		return false, "Leave the expedition before going home."
	end
	if InstanceTeleport.isPending(player) then
		return false, "Already channeling a teleport."
	end

	local leaving = PlayerHomeManager.isPlayerInHome and PlayerHomeManager.isPlayerInHome(player)
	local forceMs = opts.forceDurationMs
	if leaving then
		forceMs = forceMs or InstanceTeleport.DURATION_PZ_MS
	end
	local playerId = player:getId()
	return InstanceTeleport.begin(player, {
		kind = InstanceTeleport.KIND_HOME,
		opcode = HOME_OPCODE(),
		forceDurationMs = forceMs,
		cancelPolicy = InstanceTeleport.CANCEL_INITIATOR,
		send = InstanceTeleport.notifyHome,
		onComplete = function(memberIds)
			local p = Player(memberIds and memberIds[1] or playerId)
			if not p then
				return
			end
			if leaving then
				PlayerHomeManager.leaveHome(p)
			else
				PlayerHomeManager.enterHome(p, opts)
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

--- Group hometown channel (team recall leave). Caller supplies onComplete / onCancel.
function InstanceTeleport.requestHometownGroup(opts)
	opts = opts or {}
	opts.kind = InstanceTeleport.KIND_HOMETOWN
	opts.cancelPolicy = opts.cancelPolicy or InstanceTeleport.CANCEL_INITIATOR
	opts.opcode = opts.opcode or EXP_OPCODE()
	opts.send = opts.send or InstanceTeleport.notifyExpedition
	return InstanceTeleport.beginGroup(opts)
end
