-- Product extensions to the stock BossLever (data/libs/functions/boss_lever.lua, loaded
-- first): difficulty dialog, chained boss forms, extra arena rooms and encounters scoped
-- to the puller's instance. Extra lever config keys:
--   difficulty = { max = 25, hpPerLevel = 0.04, dmgPerLevel = 0.03 } (or true): opens the
--     boss difficulty dialog before the fight (scales HP / damage).
--   finalBoss = "Faceless Bane": chained fights end when this form dies (default boss.name).
--   extraAreas = { { from = Position(...), to = Position(...) } }: more arena rectangles.

BossLever.phaseHooks = BossLever.phaseHooks or {}

local leverMeta = getmetatable(BossLever)
local newLever = leverMeta.__call
leverMeta.__call = function(self, config)
	local lever = newLever(self, config)
	lever.extraAreas = config.extraAreas or {}
	lever.difficulty = config.difficulty == true and {} or config.difficulty
	lever.finalBoss = (config.finalBoss or config.boss.name):lower()
	lever.encounters = {}
	return lever
end

local registerLever = BossLever.register
function BossLever:register()
	if not registerLever(self) then
		return false
	end
	local zone = self:getZone()
	for _, extra in ipairs(self.extraAreas) do
		zone:addArea(extra.from, extra.to)
	end
	return true
end

--- Build the stock Lever for the players on the slot tiles and run the slot checks
--- (level, cooldown, onUseExtra). Returns the lever when the challenge may start.
---@param player Player
---@return table|nil
function BossLever:prepareLever(player)
	self.lever = Lever()
	local lever = self.lever
	lever:setPositions(self.playerPositions)
	lever:setCondition(function(creature)
		if not creature or not creature:isPlayer() then
			return true
		end

		local checkAccountType = creature:getAccountType() < ACCOUNT_TYPE_GAMEMASTER
		local isGameTester = player:hasFlag(PlayerFlag_IsGameTester)
		if checkAccountType and not isGameTester and creature:getLevel() < self.requiredLevel then
			local message = "All players need to be level " .. self.requiredLevel .. " or higher."
			creature:sendTextMessage(MESSAGE_EVENT_ADVANCE, message)
			player:sendTextMessage(MESSAGE_EVENT_ADVANCE, message)
			return false
		end

		local infoPositions = lever:getInfoPositions()
		if creature:getGroup():getId() < GROUP_TYPE_GOD and checkAccountType and not isGameTester and self:lastEncounterTime(creature) > os.time() then
			for _, posInfo in pairs(infoPositions) do
				local currentPlayer = posInfo.creature
				if currentPlayer then
					local lastEncounter = self:lastEncounterTime(currentPlayer)
					local currentTime = os.time()
					if lastEncounter and currentTime < lastEncounter then
						local timeLeft = lastEncounter - currentTime
						local timeMessage = Game.getTimeInWords(timeLeft) .. " to face " .. self.name .. " again!"
						local message = "You have to wait " .. timeMessage

						if currentPlayer ~= player then
							player:sendTextMessage(MESSAGE_EVENT_ADVANCE, "A member in your team has to wait " .. timeMessage)
						end

						currentPlayer:sendTextMessage(MESSAGE_EVENT_ADVANCE, message)
						currentPlayer:getPosition():sendMagicEffect(CONST_ME_POFF)
					end
				end
			end
			return false
		end

		return self.onUseExtra(creature, infoPositions) ~= false
	end)

	lever:checkPositions()
	if #lever:getPlayers() < self.minPlayers then
		lever:executeOnPlayers(function(creature)
			local message = string.format("You need %d qualified players for this challenge.", self.minPlayers)
			creature:sendTextMessage(MESSAGE_EVENT_ADVANCE, message)
			creature:getPosition():sendMagicEffect(CONST_ME_POFF)
		end)
		return nil
	end
	if not lever:checkConditions() then
		return nil
	end
	return lever
end

---@param player Player
---@return boolean
function BossLever:onUse(player)
	local monsterName = MonsterType(self.name):getName()
	local isParticipant = false
	for _, v in ipairs(self.playerPositions) do
		if Position(v.pos) == player:getPosition() then
			isParticipant = true
		end
	end
	if not isParticipant then
		return false
	end

	if self.disabled then
		player:sendTextMessage(MESSAGE_EVENT_ADVANCE, "The boss is temporarily disabled.")
		return true
	end

	local zone = self:getZone()
	zone:refresh() -- Refresh the zone to ensure it is up-to-date
	if zone:countPlayers(IgnoredByMonsters) > 0 then
		player:sendTextMessage(MESSAGE_EVENT_ADVANCE, "There's already someone fighting with " .. monsterName .. ".")
		return true
	end

	local lever = self:prepareLever(player)
	if not lever then
		return false
	end

	if self.difficulty and BossDifficulty then
		local players = lever:getPlayers()
		BossDifficulty.open(player, {
			lever = self,
			players = players,
			onStart = function(difficulty)
				zone:refresh()
				if zone:countPlayers(IgnoredByMonsters) > 0 then
					player:sendTextMessage(MESSAGE_EVENT_ADVANCE, "There's already someone fighting with " .. monsterName .. ".")
					return
				end
				local again = self:prepareLever(player)
				if again then
					self:startWorldEncounter(again, difficulty, player:getInstanceId())
				end
			end,
		})
		return true
	end

	self:startWorldEncounter(lever, nil, player:getInstanceId())
	return true
end

--- Open-world fight: spawn, teleport the slot players, cooldowns and the room timeout.
--- The encounter lives in the puller's instance (open-world instances are per subarea/channel).
---@param lever table
---@param difficulty number|nil
---@param instanceId string
---@return boolean
function BossLever:startWorldEncounter(lever, difficulty, instanceId)
	local zone = self:getZone()
	zone:removeMonsters()
	local playerIds = {}
	for _, p in ipairs(lever:getPlayers()) do
		playerIds[#playerIds + 1] = p:getId()
	end
	if not self:startEncounter({ instanceId = instanceId, difficulty = difficulty, playerIds = playerIds }) then
		return true
	end
	lever:teleportPlayers()
	local rottenBloodBosses = {
		["murcion"] = true,
		["chagorz"] = true,
		["ichgahal"] = true,
		["vemiath"] = true,
		["bakragore"] = true,
	}
	if rottenBloodBosses[self.name:lower()] then
		lever:executeOnPlayers(function(player)
			if player and player:isPlayer() then
				player:removeIcon("rotten-area")
				local whiteCrossIcon = player:getIcon("white-cross")
				if whiteCrossIcon then
					player:removeIcon("white-cross")
				end
				local redCrossIcon = player:getIcon("red-cross")
				if redCrossIcon then
					player:removeIcon("red-cross")
				end
			end
		end)
	end
	lever:setCooldownAllPlayers(self.name, os.time() + self.timeToFightAgain)
	if self.encounter then
		local encounter = Encounter(self.encounter)
		encounter:reset()
		encounter:start()
	end
	self:setLastEncounterTime(os.time() + self.timeToFightAgain)
	if self.timeoutEvent then
		stopEvent(self.timeoutEvent)
		self.timeoutEvent = nil
	end
	self.timeoutEvent = addEvent(function(zn)
		zn:refresh()
		zn:removePlayers()
	end, self.timeToDefeat * 1000, zone)
	return true
end

--- Spawn the lever's monsters and boss. `ctx.instanceId` (instance key of the encounter)
--- scopes every create inside the lever code; `ctx.difficulty` scales boss forms.
--- Returns ok, spawned boss monsters.
---@param ctx table|nil { instanceId, difficulty, playerIds }
---@return boolean, Monster[]
function BossLever:startEncounter(ctx)
	ctx = ctx or {}
	ctx.instanceId = Instance.normalize(ctx.instanceId)
	ctx.lever = self
	self.encounters[ctx.instanceId] = ctx
	local spawned = {}
	local function spawn()
		for _, monster in pairs(self.monsters) do
			Game.createMonster(monster.name, monster.pos, true, true)
		end
		if self.createBoss then
			local created = self.createBoss(ctx)
			if not created then
				return false
			end
			if type(created) == "userdata" then
				self:scaleForm(created, ctx)
				spawned[#spawned + 1] = created
			end
			return true
		end
		if self.bossPosition then
			logger.debug("BossLever:startEncounter - creating boss: {}", self.name)
			local monster = Game.createMonster(self.name, self.bossPosition, true, true)
			if not monster then
				return false
			end
			if not Instance.isPrivate(ctx.instanceId) then
				monster:registerEvent("BossLeverOnDeath")
			end
			self:scaleForm(monster, ctx)
			spawned[#spawned + 1] = monster
		end
		return true
	end
	local ok
	if not Instance.isWorld(ctx.instanceId) and Game.runInInstance then
		ok = Game.runInInstance(ctx.instanceId, spawn)
	else
		ok = spawn()
	end
	if not ok then
		self.encounters[ctx.instanceId] = nil
		return false, {}
	end
	return true, spawned
end

---@param instanceId string
---@return table|nil
function BossLever:encounterContext(instanceId)
	return self.encounters[Instance.normalize(instanceId)]
end

---@param instanceId string
function BossLever:clearEncounter(instanceId)
	self.encounters[Instance.normalize(instanceId)] = nil
end

---@param monster Monster
---@param ctx table|nil
function BossLever:scaleForm(monster, ctx)
	if monster and ctx and self.difficulty and BossDifficulty and BossDifficulty.apply then
		BossDifficulty.apply(monster, self, ctx.difficulty)
	end
end

--- Later boss form of a chained fight, born in the encounter's instance and scaled to its
--- difficulty. Expeditions bind it through BossLever.addPhaseHook.
---@param name string
---@param position Position
---@param instanceId string
---@return Monster|nil
function BossLever:spawnForm(name, position, instanceId)
	local ctx = self:encounterContext(instanceId) or { instanceId = Instance.normalize(instanceId) }
	local monster = Game.createMonster(name, position, true, true, nil, ctx.instanceId)
	if not monster then
		return nil
	end
	self:scaleForm(monster, ctx)
	BossLever.onPhaseSpawned(monster, self)
	return monster
end

---@param hook fun(monster: Monster, lever: BossLever)
function BossLever.addPhaseHook(hook)
	table.insert(BossLever.phaseHooks, hook)
end

---@param monster Monster
---@param lever BossLever
function BossLever.onPhaseSpawned(monster, lever)
	for _, hook in ipairs(BossLever.phaseHooks) do
		hook(monster, lever)
	end
end

--- True when `name` is the form whose death ends this lever's fight.
---@param name string
---@return boolean
function BossLever:isFinalBoss(name)
	return type(name) == "string" and name:lower() == self.finalBoss
end

--- True when the fight continues past the lever boss into later forms (finalBoss differs).
---@return boolean
function BossLever:isChained()
	return self.finalBoss ~= self.name
end

--- Open-world victory: unlock the next difficulty for the encounter players.
---@param instanceId string
function BossLever:onEncounterVictory(instanceId)
	local ctx = self:encounterContext(instanceId)
	if not ctx then
		return
	end
	if self.difficulty and BossDifficulty and BossDifficulty.unlock and ctx.playerIds then
		for _, pid in ipairs(ctx.playerIds) do
			local p = Player(pid)
			if p then
				BossDifficulty.unlock(p, self, ctx.difficulty)
			end
		end
	end
	self:clearEncounter(instanceId)
end

---@param name string
---@return BossLever|nil
function BossLever.get(name)
	if type(name) ~= "string" or name == "" then
		return nil
	end
	local lever = rawget(BossLever, name:lower())
	if type(lever) == "table" and lever.playerPositions then
		return lever
	end
	return nil
end

--- Lever whose chained fight ends with `name`.
---@param name string
---@return BossLever|nil
function BossLever.forFinalBoss(name)
	if type(name) ~= "string" then
		return nil
	end
	local key = name:lower()
	for _, lever in pairs(BossLever) do
		if type(lever) == "table" and lever.playerPositions and lever.finalBoss == key then
			return lever
		end
	end
	return nil
end

--- Tile the lever sends the player on slot `index` to (nil when the slot has none).
---@param index number
---@return Position|nil
function BossLever:arrival(index)
	local slot = self.playerPositions and (self.playerPositions[index] or self.playerPositions[1])
	return slot and slot.teleport and Position(slot.teleport) or nil
end
