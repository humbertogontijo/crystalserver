-- Exercise training (opcode 116 startTraining / stopTraining).
PlayerHomeServices = PlayerHomeServices or {}

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

local function encodeTrainingState(active)
	return string.format('{"type":"trainingState","active":%s}', active and "true" or "false")
end

local function sendTrainingState(player, active)
	if player then
		player:sendExtendedOpcode(PlayerHomeConfig.OPCODE, encodeTrainingState(active))
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
	for _, typeId in ipairs(PlayerHomeConfig.weaponsForSkill(skill)) do
		local item = player:getItemById(typeId, true)
		if item then
			local charges = item:getAttribute(ITEM_ATTRIBUTE_CHARGES)
			if charges and charges > 0 then
				return item, typeId, PlayerHomeConfig.EXERCISE_WEAPONS[typeId]
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
	if player then
		if player.setTraining then
			player:setTraining(false)
		end
		if message and message ~= "" then
			player:sendTextMessage(messageType or MESSAGE_EVENT_ADVANCE, message)
		end
		sendTrainingState(player, false)
	end
end

local function countPlayersOnDummy(dummyPos)
	if not dummyPos then
		return 0
	end
	local count = 0
	for _, state in pairs(trainingByPlayerId) do
		if state.dummyPos and state.dummyPos == dummyPos then
			count = count + 1
		end
	end
	if _G.OnExerciseTraining then
		for _, entry in pairs(_G.OnExerciseTraining) do
			if entry.dummyPos == dummyPos then
				count = count + 1
			end
		end
	end
	return count
end

local function scheduleNextTick(playerId, weaponId)
	local player = Player(playerId)
	local state = trainingByPlayerId[playerId]
	if not player or not state then
		return
	end

	local eventSpeedMultiplier = 1
	local scopedFastExercise = KV.scoped("eventscheduler"):get("fast-exercise")
	if scopedFastExercise then
		eventSpeedMultiplier = 0.5
	end

	local vocation = player:getVocation()
	local delay = (vocation:getBaseAttackSpeed() / configManager.getFloat(configKeys.RATE_EXERCISE_TRAINING_SPEED))
		* eventSpeedMultiplier
	state.event = addEvent(trainingTick, delay, playerId, weaponId)
end

local function trainingTick(playerId, _lastWeaponId)
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
	local dummyId = state.dummyId
	local tile = dummyPos and Tile(dummyPos) or nil
	local targetItem = tile and tile:getItemById(dummyId) or nil
	if not targetItem then
		leaveTraining(playerId, "Someone has moved the dummy, the training has stopped.", MESSAGE_FAILURE)
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
	if weaponCharges <= 0 then
		weapon:remove(1)
		leaveTraining(playerId, "Your training weapon has disappeared.", MESSAGE_EVENT_ADVANCE)
		return
	end

	local rate = (dummies[dummyId] or 100) / 100
	if meta.skill == "magic" then
		player:addManaSpent(math.floor((PlayerHomeConfig.TRAIN_MANA_SPENT or 600) * rate))
	else
		local skillId = SKILL_MAP[meta.skill]
		if skillId then
			player:addSkillTries(skillId, math.floor((PlayerHomeConfig.TRAIN_SKILL_TRIES or 7) * rate))
		end
	end

	weapon:setAttribute(ITEM_ATTRIBUTE_CHARGES, weaponCharges - 1)
	dummyPos:sendMagicEffect(CONST_ME_HITAREA)
	if meta.effect then
		playerPosition:sendDistanceEffect(dummyPos, meta.effect)
	end

	if (weapon:getAttribute(ITEM_ATTRIBUTE_CHARGES) or 0) <= 0 then
		weapon:remove(1)
		local nextWeapon = findWeaponForSkill(player, state.skill)
		if not nextWeapon then
			leaveTraining(playerId, "Your training weapon has disappeared.", MESSAGE_EVENT_ADVANCE)
			return
		end
	end

	scheduleNextTick(playerId, weaponId)
end

function PlayerHomeServices.startTraining(player, opts)
	if not player then
		return false, "Invalid player."
	end
	opts = opts or {}
	local skill = tostring(opts.skill or "")
	if skill == "" then
		return false, "Choose an exercise weapon type."
	end

	local dummy = opts.dummy
	if type(dummy) ~= "table" then
		return false, "Select an exercise dummy."
	end
	local dummyPos = Position(
		math.floor(tonumber(dummy.x) or 0),
		math.floor(tonumber(dummy.y) or 0),
		math.floor(tonumber(dummy.z) or 0)
	)

	local playerId = player:getId()
	if trainingByPlayerId[playerId] or (_G.OnExerciseTraining and _G.OnExerciseTraining[playerId]) then
		return false, "Already training."
	end

	local tile = Tile(dummyPos)
	if not tile then
		return false, "Invalid exercise dummy."
	end

	local dummyId = nil
	local targetItem = nil
	for id in pairs(dummies) do
		local item = tile:getItemById(id)
		if item then
			dummyId = id
			targetItem = item
			break
		end
	end
	if not dummyId or not targetItem or not isDummy(dummyId) then
		return false, "That is not an exercise dummy."
	end

	local playerPos = player:getPosition()
	if playerPos.z ~= dummyPos.z then
		return false, "The exercise dummy is on another floor."
	end

	local weapon, weaponId, weaponMeta = findWeaponForSkill(player, skill)
	if not weapon or not weaponMeta then
		return false, "Carry an exercise weapon with charges (buy from hireling)."
	end

	if not weaponMeta.allowFarUse and playerPos:getDistance(dummyPos) > 1 then
		return false, "Get closer to the dummy."
	end

	if not playerPos:isProtectionZoneTile() then
		return false, "You need to be in a protection zone."
	end

	local playerHouse = player:getTile():getHouse()
	local targetHouse = tile:getHouse()
	if targetHouse and isDummy(dummyId) then
		if playerHouse ~= targetHouse then
			return false, "You must be inside the house to use this dummy."
		end
		local maxOnDummy = configManager.getNumber(configKeys.MAX_ALLOWED_ON_A_DUMMY)
		if countPlayersOnDummy(dummyPos) >= maxOnDummy then
			return false, "That exercise dummy is busy."
		end
	end

	trainingByPlayerId[playerId] = {
		skill = skill,
		dummyPos = dummyPos,
		dummyId = dummyId,
		targetItem = targetItem,
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

function PlayerHomeServices.stopTraining(player)
	if not player then
		return false, "Invalid player."
	end
	if not trainingByPlayerId[player:getId()] then
		return false, "Not training."
	end
	leaveTraining(player:getId(), "Training stopped.", MESSAGE_EVENT_ADVANCE)
	return true
end

function PlayerHomeServices.onLeave(player)
	if player then
		leaveTraining(player:getId())
	end
end
