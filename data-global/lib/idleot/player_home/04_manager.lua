PlayerHomeManager = {}

-- playerId -> session { instance, playerGuid, entered, channel }
local sessionsByPlayerId = {}
-- Incremental channels for the Home place (0, 1, 2, ...).
local homeChannelsInUse = {}

local function allocateHomeChannel(sessionKey)
	local channel = 0
	while homeChannelsInUse[channel] do
		channel = channel + 1
	end
	homeChannelsInUse[channel] = sessionKey or true
	return channel
end

local function releaseHomeChannel(channel)
	if channel == nil then
		return
	end
	homeChannelsInUse[math.floor(tonumber(channel) or -1)] = nil
end

local function encodeError(message)
	return string.format('{"type":"error","message":%s}', string.format("%q", tostring(message or "error")))
end

local function reply(player, payloadJson)
	if player then
		player:sendExtendedOpcode(PlayerHomeConfig.OPCODE, payloadJson)
	end
end

local function saveReturnPos(player)
	local pos = player:getPosition()
	player:setStorageValue(PlayerHomeConfig.STORAGE_RETURN_X, pos.x)
	player:setStorageValue(PlayerHomeConfig.STORAGE_RETURN_Y, pos.y)
	player:setStorageValue(PlayerHomeConfig.STORAGE_RETURN_Z, pos.z)
end

local function loadReturnPos(player)
	local x = player:getStorageValue(PlayerHomeConfig.STORAGE_RETURN_X)
	local y = player:getStorageValue(PlayerHomeConfig.STORAGE_RETURN_Y)
	local z = player:getStorageValue(PlayerHomeConfig.STORAGE_RETURN_Z)
	if x < 0 or y < 0 or z < 0 then
		local town = player:getTown()
		if town then
			return town:getTemplePosition()
		end
		return player:getPosition()
	end
	return Position(x, y, z)
end

function PlayerHomeManager.getSession(player)
	if not player then
		return nil
	end
	return sessionsByPlayerId[player:getId()]
end

function PlayerHomeManager.isPositionInAnyHome(pos)
	if not pos then
		return false
	end
	for _, session in pairs(sessionsByPlayerId) do
		if session.instance and PlayerHomeInstance.contains(session.instance, pos) then
			return true
		end
	end
	return false
end

function PlayerHomeManager.isPlayerInHome(player)
	local session = PlayerHomeManager.getSession(player)
	if not session or not session.instance or not player then
		return false
	end
	return PlayerHomeInstance.contains(session.instance, player:getPosition())
end

function PlayerHomeManager.saveIfInHome(player)
	local session = PlayerHomeManager.getSession(player)
	if not session or not session.instance then
		return
	end
	PlayerHomePersist.savePlayer(player, session.instance)
end

local function homeBounds(instance)
	if not instance or not instance.origin then
		return nil
	end
	return {
		x = instance.origin.x,
		y = instance.origin.y,
		w = instance.width or PlayerHomeConfig.OUTER_SIZE,
		h = instance.height or PlayerHomeConfig.OUTER_SIZE,
	}
end

local function endSession(player, session, teleportOut)
	if not session then
		return
	end
	local instance = session.instance
	local engineId = instance and instance.instanceId or nil
	local channel = session.channel
	if player then
		PlayerHomePersist.savePlayer(player, instance)
		sessionsByPlayerId[player:getId()] = nil
		if teleportOut then
			local ret = loadReturnPos(player)
			if InstanceWorld and InstanceWorld.exitToOpenWorld then
				InstanceWorld.exitToOpenWorld(player, ret)
			elseif InstanceWorld and InstanceWorld.travel then
				InstanceWorld.travel(player, ret)
			else
				player:teleportTo(ret)
			end
			if InstanceTeleport and InstanceTeleport.sendArrivalEffect then
				InstanceTeleport.sendArrivalEffect(player, InstanceTeleport.KIND_HOME)
			elseif ret and ret.sendMagicEffect then
				ret:sendMagicEffect(CONST_ME_TELEPORT)
			end
		end
	end
	if instance then
		PlayerHomeInstance.teardown(instance)
	end
	if engineId then
		if InstanceWorld and InstanceWorld.forgetFloors then
			InstanceWorld.forgetFloors(engineId)
		end
		if ExpeditionInstance and ExpeditionInstance.free then
			ExpeditionInstance.free(engineId)
		end
	end
	releaseHomeChannel(channel)
	if player and InstanceWorld and InstanceWorld.sendBounds then
		InstanceWorld.sendBounds(player, true)
	end
end

function PlayerHomeManager.leaveHome(player)
	local session = PlayerHomeManager.getSession(player)
	if not session then
		return false, "You are not at home."
	end
	if PlayerHomeServices and PlayerHomeServices.onLeave then
		PlayerHomeServices.onLeave(player)
	end
	endSession(player, session, true)
	return true
end

--- Tear down home session without traveling (caller owns the next hop, e.g. temple recall).
function PlayerHomeManager.closeHomeSession(player)
	local session = PlayerHomeManager.getSession(player)
	if not session then
		return false
	end
	if PlayerHomeServices and PlayerHomeServices.onLeave then
		PlayerHomeServices.onLeave(player)
	end
	endSession(player, session, false)
	return true
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

--- Enter personal home instance (no channel — InstanceTeleport.requestHome arms IT).
function PlayerHomeManager.enterHome(player, opts)
	opts = opts or {}
	if not player then
		return false, "Invalid player."
	end
	if not fromExpeditionSafe(player, opts) then
		return false, "Leave the expedition before going home."
	end
	if PlayerHomeManager.isPlayerInHome(player) then
		return PlayerHomeManager.leaveHome(player)
	end

	local existing = PlayerHomeManager.getSession(player)
	if existing then
		endSession(player, existing, false)
	end

	local engineId = ExpeditionInstance and ExpeditionInstance.allocate and ExpeditionInstance.allocate() or nil
	if engineId == nil then
		return false, "Failed to allocate home instance."
	end

	local instance = PlayerHomeInstance.build(engineId)
	if not instance then
		if ExpeditionInstance and ExpeditionInstance.free then
			ExpeditionInstance.free(engineId)
		end
		return false, "Failed to build home instance."
	end

	local channel = allocateHomeChannel(player:getGuid())
	instance.instanceId = engineId
	instance.channel = channel
	if instance.house and instance.house.setInstanceOwner then
		instance.house:setInstanceOwner(engineId, player:getGuid())
	end
	if InstanceWorld and InstanceWorld.rememberFloors then
		local z = instance.entry and instance.entry.z or PlayerHomeConfig.INSTANCE_Z
		InstanceWorld.rememberFloors(engineId, { [z] = true })
	end

	saveReturnPos(player)
	if PlayerHomePersist.hasItems(player) then
		PlayerHomePersist.loadPlayer(player, instance)
	else
		PlayerHomeInstance.stampStarterFurniture(instance, player)
		PlayerHomePersist.savePlayer(player, instance)
	end
	PlayerHomeInstance.bindFurnitureOwnership(instance, player)
	PlayerHomeInstance.spawnHireling(instance)

	sessionsByPlayerId[player:getId()] = {
		instance = instance,
		playerGuid = player:getGuid(),
		entered = true,
		channel = channel,
	}

	local entered = false
	if not (InstanceWorld and InstanceWorld.enterInstance) then
		logger.error("[PlayerHome] InstanceWorld.enterInstance missing — cannot enter home")
	else
		entered = InstanceWorld.enterInstance(player, engineId, instance.entry, "home") and true or false
	end
	if not entered then
		sessionsByPlayerId[player:getId()] = nil
		if instance.house and instance.house.clearInstanceOwner then
			instance.house:clearInstanceOwner(engineId)
		end
		PlayerHomeInstance.teardown(instance)
		if InstanceWorld and InstanceWorld.forgetFloors then
			InstanceWorld.forgetFloors(engineId)
		end
		if ExpeditionInstance and ExpeditionInstance.free then
			ExpeditionInstance.free(engineId)
		end
		releaseHomeChannel(channel)
		return false, "Failed to enter home instance."
	end
	if InstanceTeleport and InstanceTeleport.sendArrivalEffect then
		InstanceTeleport.sendArrivalEffect(player, InstanceTeleport.KIND_HOME)
	elseif instance.entry and instance.entry.sendMagicEffect then
		instance.entry:sendMagicEffect(CONST_ME_TELEPORT)
	end
	if InstanceWorld and InstanceWorld.sendBounds then
		InstanceWorld.sendBounds(player, true)
	end
	local tomes = PlayerHomeConfig.shaperTomesStorage and PlayerHomeConfig.shaperTomesStorage() or 0
	if tomes and tomes > 0 and player:getStorageValue(tomes) < 1 then
		player:setStorageValue(tomes, 1)
	end
	return true
end

--- Topbar / opcode goHome — InstanceTeleport owns the channel + hop.
function PlayerHomeManager.goHome(player, opts)
	if InstanceTeleport and InstanceTeleport.requestHome then
		return InstanceTeleport.requestHome(player, opts)
	end
	return PlayerHomeManager.enterHome(player, opts)
end

function PlayerHomeManager.onLogout(player)
	local session = PlayerHomeManager.getSession(player)
	if PlayerHomeServices and PlayerHomeServices.onLeave then
		PlayerHomeServices.onLeave(player)
	end
	if not session then
		return true
	end
	-- Save + teardown, leave player at return pos for next login.
	endSession(player, session, true)
	return true
end

function PlayerHomeManager.onDeath(player)
	if PlayerHomeServices and PlayerHomeServices.onLeave then
		PlayerHomeServices.onLeave(player)
	end
	-- Keep items, eject to return pos so corpse isn't stranded in instance.
	local session = PlayerHomeManager.getSession(player)
	if not session then
		return
	end
	endSession(player, session, true)
end

function PlayerHomeManager.onLogin(_player)
	-- Home NPC spawn remains on enter-home (PlayerHomeInstance.spawnHireling).
	-- Top-bar hireling trade does not require owned lamps/hirelings.
end

function PlayerHomeManager.onStartup()
	PlayerHomeInstance.ensureTemplate()
	sessionsByPlayerId = {}
	homeChannelsInUse = {}
end

function PlayerHomeManager.onServerSave()
	for _, player in ipairs(Game.getPlayers()) do
		PlayerHomeManager.saveIfInHome(player)
	end
end

function PlayerHomeManager.handleOpcode(player, buffer)
	if type(buffer) ~= "string" or buffer == "" then
		return
	end

	local msg = JsonParser.decode(buffer)
	if type(msg) ~= "table" then
		return
	end

	local action = tostring(msg.action or "")
	-- Training is a home-instance service (dummies); keep on this opcode.
	if action == "startTraining" then
		local ok, errMsg = PlayerHomeServices.startTraining(player, {
			skill = msg.skill,
			dummy = msg.dummy,
		})
		if not ok then
			player:sendTextMessage(MESSAGE_FAILURE, errMsg or "Training failed.")
			reply(player, encodeError(errMsg))
		end
		return
	end
	if action == "stopTraining" then
		local ok, errMsg = PlayerHomeServices.stopTraining(player)
		if not ok then
			player:sendTextMessage(MESSAGE_FAILURE, errMsg or "Not training.")
			reply(player, encodeError(errMsg))
		end
		return
	end

	-- Instance teleport verbs (channel + hop owned by InstanceTeleport).
	if action == "channelCancel" then
		if InstanceTeleport and InstanceTeleport.handleChannelCancel then
			InstanceTeleport.handleChannelCancel(player)
		end
		return
	end
	if action == "goHometown" then
		local ok, errMsg
		if InstanceTeleport and InstanceTeleport.requestHometown then
			ok, errMsg = InstanceTeleport.requestHometown(player)
		else
			ok, errMsg = false, "Recall is unavailable."
		end
		if not ok then
			player:sendTextMessage(MESSAGE_FAILURE, errMsg or "Could not recall.")
			reply(player, encodeError(errMsg))
		end
		return
	end
	if action == "goHome" or action == "leaveHome" then
		local ok, errMsg = PlayerHomeManager.goHome(player)
		if not ok then
			player:sendTextMessage(MESSAGE_FAILURE, errMsg or "Could not enter home.")
			reply(player, encodeError(errMsg))
		end
		return
	end
end
