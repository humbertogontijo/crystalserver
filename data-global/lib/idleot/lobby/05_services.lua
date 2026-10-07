-- Exercise training on any targetable dummy (opcode 116 startTraining / stopTraining).
LobbyServices = LobbyServices or {}

local trainingByPlayerId = {}
local dummies = Game.getDummies()

local SKILL_MAP = {
	sword = SKILL_SWORD,
	axe = SKILL_AXE,
	club = SKILL_CLUB,
	distance = SKILL_DISTANCE,
	shield = SKILL_SHIELD,
	fist = SKILL_FIST,
}

local function sendTrainingState(player, active)
	if player then
		player:sendExtendedOpcode(
			LobbyConfig.TRAVEL_OPCODE,
			string.format('{"type":"trainingState","active":%s}', active and "true" or "false")
		)
	end
end

local function isDummy(id)
	id = tonumber(id) or 0
	return dummies[id] and dummies[id] > 0
end

local function findWeaponForSkill(player, skill)
	if not player or type(skill) ~= "string" then
		return nil
	end
	for _, typeId in ipairs(LobbyConfig.weaponsForSkill(skill)) do
		local item = player:getItemById(typeId, true)
		if item then
			local charges = item:getAttribute(ITEM_ATTRIBUTE_CHARGES)
			if charges and charges > 0 then
				return item, typeId, LobbyConfig.EXERCISE_WEAPONS[typeId]
			end
		end
	end
	return nil
end

local function leaveTraining(playerId, message, messageType)
	local state = trainingByPlayerId[playerId]
	if state and state.event then
		stopEvent(state.event)
	end
	if state and state.targetItem then
		pcall(function()
			state.targetItem:actor(false)
		end)
	end
	trainingByPlayerId[playerId] = nil

	local player = Player(playerId)
	if player and state then
		if player.setTraining then
			player:setTraining(false)
		end
		if message and message ~= "" then
			player:sendTextMessage(messageType or MESSAGE_EVENT_ADVANCE, message)
		end
		sendTrainingState(player, false)
	end
end

-- Instances share map tiles, so the same dummy position is counted per instance.
local function countPlayersOnDummy(dummyPos, instanceId)
	local count = 0
	for _, state in pairs(trainingByPlayerId) do
		if state.dummyPos and state.dummyPos == dummyPos and state.instanceId == instanceId then
			count = count + 1
		end
	end
	return count
end

local function findDummyOnTile(tile)
	if not tile then
		return nil
	end
	for id in pairs(dummies) do
		if isDummy(id) then
			local item = tile:getItemById(id)
			if item then
				return item, id
			end
		end
	end
	return nil
end

local function positionFromMessage(value)
	if type(value) ~= "table" then
		return nil
	end
	local x, y, z = tonumber(value.x), tonumber(value.y), tonumber(value.z)
	if not x or not y or not z then
		return nil
	end
	return Position(math.floor(x), math.floor(y), math.floor(z))
end

-- Forward-declared so scheduleNextTick closes over the local, not a nil global.
local trainingTick

local function scheduleNextTick(playerId, weaponId)
	local player = Player(playerId)
	local state = trainingByPlayerId[playerId]
	if not player or not state then
		return
	end
	local eventSpeedMultiplier = KV.scoped("eventscheduler"):get("fast-exercise") and 0.5 or 1
	local delay = (player:getVocation():getBaseAttackSpeed() / configManager.getFloat(configKeys.RATE_EXERCISE_TRAINING_SPEED))
		* eventSpeedMultiplier
	state.event = addEvent(trainingTick, delay, playerId, weaponId)
end

trainingTick = function(playerId)
	local player = Player(playerId)
	if not player then
		leaveTraining(playerId)
		return
	end
	local state = trainingByPlayerId[playerId]
	if not state then
		return
	end
	if player:isTraining() == 0 then
		leaveTraining(playerId, "You have stopped training.", MESSAGE_FAILURE)
		return
	end

	local dummyPos = state.dummyPos
	local tile = Tile(dummyPos)
	local targetItem = tile and tile:getItemById(state.dummyId) or nil
	if not targetItem then
		leaveTraining(playerId, "The dummy is gone, the training has stopped.", MESSAGE_FAILURE)
		return
	end
	state.targetItem = targetItem

	local playerPosition = player:getPosition()
	if not playerPosition:isProtectionZoneTile() then
		leaveTraining(playerId, "You are no longer in a protection zone, the training has stopped.", MESSAGE_FAILURE)
		return
	end

	local weapon, weaponId, meta = findWeaponForSkill(player, state.skill)
	if not weapon or not meta then
		leaveTraining(playerId, "Training stopped - no exercise weapon with charges.", MESSAGE_EVENT_ADVANCE)
		return
	end

	local weaponCharges = weapon:getAttribute(ITEM_ATTRIBUTE_CHARGES) or 0
	local rate = (dummies[state.dummyId] or 100) / 100
	if meta.skill == "magic" then
		player:addManaSpent(math.floor(LobbyConfig.TRAIN_MANA_SPENT * rate))
	else
		local skillId = SKILL_MAP[meta.skill]
		if skillId then
			player:addSkillTries(skillId, math.floor(LobbyConfig.TRAIN_SKILL_TRIES * rate))
		end
	end

	weapon:setAttribute(ITEM_ATTRIBUTE_CHARGES, weaponCharges - 1)
	-- addEvent has no instance actor and the dummy tile holds no creature, so without the
	-- scope the hit effect would only reach the open world.
	Game.runInInstance(player:getInstanceId() or 0, function()
		if meta.effect then
			playerPosition:sendDistanceEffect(dummyPos, meta.effect)
		end
		dummyPos:sendMagicEffect(CONST_ME_HITAREA)
	end)

	if (weapon:getAttribute(ITEM_ATTRIBUTE_CHARGES) or 0) <= 0 then
		weapon:remove(1)
		if not findWeaponForSkill(player, state.skill) then
			leaveTraining(playerId, "Your training weapon has disappeared.", MESSAGE_EVENT_ADVANCE)
			return
		end
	end

	scheduleNextTick(playerId, weaponId)
end

function LobbyServices.startTraining(player, opts)
	if not player then
		return false, "Invalid player."
	end
	opts = opts or {}
	local skill = tostring(opts.skill or "")
	if skill == "" then
		return false, "Choose an exercise weapon type."
	end
	local playerId = player:getId()
	if trainingByPlayerId[playerId] or (_G.OnExerciseTraining and _G.OnExerciseTraining[playerId]) then
		return false, "Already training."
	end

	local dummyPos = positionFromMessage(opts.dummy)
	if not dummyPos then
		return false, "Select an exercise dummy."
	end
	local targetItem, dummyId = findDummyOnTile(Tile(dummyPos))
	if not targetItem then
		return false, "There is no exercise dummy there."
	end

	local weapon, weaponId, weaponMeta = findWeaponForSkill(player, skill)
	if not weapon or not weaponMeta then
		return false, "Carry an exercise weapon with charges (buy from hireling)."
	end
	local playerPos = player:getPosition()
	if playerPos.z ~= dummyPos.z then
		return false, "That exercise dummy is not in line of sight."
	end
	if not weaponMeta.allowFarUse and playerPos:getDistance(dummyPos) > 1 then
		return false, "Get closer to the dummy."
	end
	local instanceId = player:getInstanceId() or 0
	if
		math.abs(playerPos.x - dummyPos.x) > LobbyConfig.TRAIN_MAX_RANGE_X
		or math.abs(playerPos.y - dummyPos.y) > LobbyConfig.TRAIN_MAX_RANGE_Y
		or not playerPos:isSightClear(dummyPos, true, instanceId)
	then
		return false, "That exercise dummy is not in line of sight."
	end
	if not playerPos:isProtectionZoneTile() then
		return false, "You need to be in a protection zone."
	end

	local dummyHouse = Tile(dummyPos):getHouse()
	if dummyHouse and player:getTile():getHouse() ~= dummyHouse then
		return false, "You must be inside the house to use this dummy."
	end
	local maxOnDummy = configManager.getNumber(configKeys.MAX_ALLOWED_ON_A_DUMMY)
	if dummyHouse and maxOnDummy and maxOnDummy > 0 and countPlayersOnDummy(dummyPos, instanceId) >= maxOnDummy then
		return false, "That exercise dummy is busy."
	end

	trainingByPlayerId[playerId] = {
		skill = skill,
		dummyPos = dummyPos,
		dummyId = dummyId,
		targetItem = targetItem,
		instanceId = instanceId,
	}
	if player.setTraining then
		player:setTraining(true)
	end
	pcall(function()
		targetItem:actor(true)
	end)
	player:sendTextMessage(MESSAGE_EVENT_ADVANCE, "You have started training on an exercise dummy.")
	sendTrainingState(player, true)
	trainingByPlayerId[playerId].event = addEvent(trainingTick, 0, playerId, weaponId)
	return true
end

function LobbyServices.stopTraining(player)
	if not player or not trainingByPlayerId[player:getId()] then
		return false, "Not training."
	end
	leaveTraining(player:getId(), "Training stopped.", MESSAGE_EVENT_ADVANCE)
	return true
end

--- A client reattached to a body that kept training offline: restore the stop button.
function LobbyServices.onClientAttached(player)
	if player and trainingByPlayerId[player:getId()] then
		sendTrainingState(player, true)
	end
end

function LobbyServices.onLeave(player)
	if player then
		leaveTraining(player:getId())
	end
end
