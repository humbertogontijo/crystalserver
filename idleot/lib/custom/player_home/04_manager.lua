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

--- Grant a free hireling + trader/banker skills (first login via SendFirstItems).
--- Home trader NPC is the play path; lamps are not required.
function PlayerHomeManager.ensureStarterHireling(player)
	if not player or not player:isPlayer() then
		return
	end

	if ProductHirelingSync then
		ProductHirelingSync.ensurePlayerHirelingsLoaded(player)
	end

	local okHas, hasHirelings = pcall(function()
		return player:hasHirelings()
	end)
	if not okHas then
		logger.warn("[PlayerHome] hasHirelings failed for {}: {}", player:getName(), hasHirelings)
		return
	end

	local granted = false
	if not hasHirelings then
		local hirelingName = string.format("%s's Hireling", player:getName())
		local okAdd, hireling = pcall(function()
			return player:addNewHireling(hirelingName, HIRELING_SEX and HIRELING_SEX.MALE or 1)
		end)
		if okAdd and hireling then
			granted = true
		else
			-- DB row may exist without runtime registration from a prior login.
			if not (ProductHirelingSync and ProductHirelingSync.ensurePlayerHirelingsLoaded(player)) then
				logger.warn(
					"[PlayerHome] failed to grant starter hireling to {} ({})",
					player:getName(),
					okAdd and "nil" or tostring(hireling)
				)
			end
		end
	end

	pcall(function()
		if player.enableHirelingSkill then
			player:enableHirelingSkill("trader")
			player:enableHirelingSkill("banker")
		end
	end)

	if granted then
		player:sendTextMessage(
			MESSAGE_EVENT_ADVANCE,
			"A hireling waits at your home to trade and bank."
		)
	end
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
			if InstanceWorld and InstanceWorld.travel then
				InstanceWorld.travel(player, ret)
			else
				player:teleportTo(ret)
			end
			if ret and ret.sendMagicEffect then
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

function PlayerHomeManager.goHome(player)
	if not player then
		return false, "Invalid player."
	end

	-- Block mid-expedition teleports; client should show leave confirmation first.
	if ExpeditionManager and ExpeditionManager.getSessionByPlayer and ExpeditionManager.getSessionByPlayer(player) then
		return false, "Leave the expedition before going home."
	end

	-- Toggle leave if already inside (no protection-zone check).
	if PlayerHomeManager.isPlayerInHome(player) then
		return PlayerHomeManager.leaveHome(player)
	end

	if PzTeleport and PzTeleport.isAllowed then
		local allowed, pzErr = PzTeleport.isAllowed(player)
		if not allowed then
			return false, pzErr or "You can only go home from a protection zone."
		end
	end

	-- Already has a session object (shouldn't happen) - clean it.
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
	if InstanceWorld and InstanceWorld.enterInstance then
		entered = InstanceWorld.enterInstance(player, engineId, instance.entry, "home") and true or false
	else
		if player.setInstanceId then
			player:setInstanceId(engineId)
		end
		entered = player:teleportTo(instance.entry) and true or false
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
	if instance.entry and instance.entry.sendMagicEffect then
		instance.entry:sendMagicEffect(CONST_ME_TELEPORT)
	end
	if InstanceWorld and InstanceWorld.sendBounds then
		InstanceWorld.sendBounds(player, true)
	end
	-- Ensure imbuement shrine is usable (Forgotten Knowledge gate).
	local tomes = PlayerHomeConfig.shaperTomesStorage and PlayerHomeConfig.shaperTomesStorage() or 0
	if tomes and tomes > 0 and player:getStorageValue(tomes) < 1 then
		player:setStorageValue(tomes, 1)
	end
	return true
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

local function decodeOpcode(buffer)
	if type(buffer) ~= "string" or buffer == "" then
		return nil
	end
	if ExpeditionJson and ExpeditionJson.decode then
		local ok, decoded = pcall(ExpeditionJson.decode, buffer)
		if ok and type(decoded) == "table" then
			return decoded
		end
	end
	if SquadJson and SquadJson.decode then
		local ok, decoded = pcall(SquadJson.decode, buffer)
		if ok and type(decoded) == "table" then
			return decoded
		end
	end
	local action = nil
	if buffer:find('"startTraining"', 1, true) then
		action = "startTraining"
	elseif buffer:find('"stopTraining"', 1, true) then
		action = "stopTraining"
	elseif buffer:find('"leaveHome"', 1, true) then
		action = "leaveHome"
	elseif buffer:find('"goHome"', 1, true) then
		action = "goHome"
	else
		return nil
	end
	local msg = { action = action }
	msg.skill = buffer:match('"skill"%s*:%s*"([^"]+)"')
	local dx = buffer:match('"dummy"%s*:%s*{%s*"x"%s*:%s*(%-?%d+)')
	local dy = buffer:match('"y"%s*:%s*(%-?%d+)')
	local dz = buffer:match('"z"%s*:%s*(%-?%d+)')
	if dx and dy and dz then
		msg.dummy = { x = tonumber(dx), y = tonumber(dy), z = tonumber(dz) }
	end
	return msg
end

function PlayerHomeManager.handleOpcode(player, buffer)
	if type(buffer) ~= "string" or buffer == "" then
		return
	end

	local msg = decodeOpcode(buffer)
	if type(msg) ~= "table" then
		return
	end

	local action = tostring(msg.action or "")
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

	if action ~= "goHome" and action ~= "leaveHome" then
		return
	end

	local ok, errMsg
	if action == "leaveHome" then
		ok, errMsg = PlayerHomeManager.leaveHome(player)
	else
		ok, errMsg = PlayerHomeManager.goHome(player)
	end
	if ok then
		return
	end
	local msg = errMsg or "Could not enter home."
	player:sendTextMessage(MESSAGE_FAILURE, msg)
	reply(player, encodeError(msg))
end
