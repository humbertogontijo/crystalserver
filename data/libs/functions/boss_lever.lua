---@class BossLever
---@field private name string
---@field private bossPosition Position
---@field private createBoss function
---@field private timeToFightAgain number
---@field private timeToDefeat number
---@field private minPlayers number
---@field private timeAfterKill number
---@field private requiredLevel number
---@field private disabled boolean
---@field private onUseExtra function
---@field private _position Position
---@field private _uid number
---@field private _aid number
---@field private playerPositions {pos: Position, teleport: Position}[]
---@field private area {from: Position, to: Position}
---@field private monsters {name: string, pos: Position}[]
---@field private exitTeleporter Position
---@field private exit Position
---@field private encounter Encounter
---@field private timeoutEvent Event
---@field private disableCooldown boolean
---@field private difficulty table|nil
---@field private finalBoss string|nil
---@field private encounters table<number, table>
---@field private extraAreas {from: Position, to: Position}[]
BossLever = {}
BossLever.phaseHooks = BossLever.phaseHooks or {}

--[[
local config = {
	boss = {
		name = "Faceless Bane",
		position = Position(33617, 32561, 13)
	}
	requiredLevel = 250,
	timeToFightAgain = 10 * 60 * 60, -- In seconds
	minPlayers = 4,
	playerPositions = {
		{ pos = Position(33638, 32562, 13), teleport = Position(33617, 32567, 13) },
		{ pos = Position(33639, 32562, 13), teleport = Position(33617, 32567, 13) },
		{ pos = Position(33640, 32562, 13), teleport = Position(33617, 32567, 13) },
		{ pos = Position(33641, 32562, 13), teleport = Position(33617, 32567, 13) },
		{ pos = Position(33642, 32562, 13), teleport = Position(33617, 32567, 13) },
	},
	specPos = {
		from = Position(33607, 32553, 13),
		to = Position(33627, 32570, 13)
	},
	onUseExtra = function(player, infoPositions)
		player:teleportTo(Position(33618, 32523, 15))
		player:getPosition():sendMagicEffect(CONST_ME_TELEPORT)
	end,
	exit = Position(33618, 32523, 15),
	-- Optional: opens the boss difficulty dialog before the fight (scales HP / damage).
	difficulty = { max = 25, hpPerLevel = 0.04, dmgPerLevel = 0.03 },
	-- Optional: chained fights end when this form dies (default: boss.name).
	finalBoss = "Faceless Bane",
	-- Optional: more arena rectangles for fights spread over several rooms.
	extraAreas = { { from = Position(33600, 32540, 13), to = Position(33606, 32552, 13) } },
}
]]
setmetatable(BossLever, {
	---@param self BossLever
	---@param config table
	__call = function(self, config)
		local boss = config.boss
		if not boss then
			error("BossLever: boss is required")
		end
		return setmetatable({
			name = boss.name:lower(),
			encounter = config.encounter,
			bossPosition = boss.position,
			timeToFightAgain = config.timeToFightAgain or configManager.getNumber(configKeys.BOSS_DEFAULT_TIME_TO_FIGHT_AGAIN),
			timeToDefeat = config.timeToDefeat or configManager.getNumber(configKeys.BOSS_DEFAULT_TIME_TO_DEFEAT),
			timeAfterKill = config.timeAfterKill or 60,
			requiredLevel = config.requiredLevel or 0,
			createBoss = boss.createFunction,
			disabled = config.disabled,
			minPlayers = config.minPlayers or 1,
			playerPositions = config.playerPositions,
			onUseExtra = config.onUseExtra or function() end,
			exitTeleporter = config.exitTeleporter,
			exit = config.exit,
			area = config.specPos,
			extraAreas = config.extraAreas or {},
			monsters = config.monsters or {},
			disableCooldown = config.disableCooldown,
			difficulty = config.difficulty == true and {} or config.difficulty,
			finalBoss = (config.finalBoss or boss.name):lower(),
			encounters = {},
			_position = nil,
			_uid = nil,
			_aid = nil,
		}, { __index = BossLever })
	end,
})

---@param self BossLever
---@param position Position
---@return BossLever
function BossLever:position(position)
	self._position = position
	return self
end

---@param self BossLever
---@param uid number
---@return BossLever
function BossLever:uid(uid)
	self._uid = uid
	return self
end

---@param self BossLever
---@param aid number
---@return BossLever
function BossLever:aid(aid)
	self._aid = aid
	return self
end

function BossLever:kvScope()
	local mType = MonsterType(self.name)
	if not mType then
		error("BossLever: boss name is invalid")
	end
	return "boss.cooldown." .. toKey(tostring(mType:raceId()))
end

---@param self BossLever
---@param player Player
---@return number
function BossLever:lastEncounterTime(player)
	if not player or self.disableCooldown then
		return 0
	end
	return player:getBossCooldown(self.name)
end

---@param self BossLever
---@param time number
---@return boolean
function BossLever:setLastEncounterTime(time)
	local info = self.lever:getInfoPositions()
	if not info then
		logger.error("BossLever:setLastEncounterTime - lever:getInfoPositions() returned nil")
		return false
	end
	for _, v in pairs(info) do
		if v.creature then
			local player = v.creature:getPlayer()
			if player then
				player:setBossCooldown(self.name, time)
			end
		end
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
					self:startWorldEncounter(again, difficulty)
				end
			end,
		})
		return true
	end

	self:startWorldEncounter(lever, nil)
	return true
end

--- Open-world fight: spawn, teleport the slot players, cooldowns and the room timeout.
---@param lever table
---@param difficulty number|nil
---@return boolean
function BossLever:startWorldEncounter(lever, difficulty)
	local zone = self:getZone()
	zone:removeMonsters()
	local playerIds = {}
	for _, p in ipairs(lever:getPlayers()) do
		playerIds[#playerIds + 1] = p:getId()
	end
	if not self:startEncounter({ instanceId = 0, difficulty = difficulty, playerIds = playerIds }) then
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

--- Spawn the lever's monsters and boss. `ctx.instanceId` (private instance, 0 = open world)
--- scopes every create inside the lever code; `ctx.difficulty` scales boss forms.
--- Returns ok, spawned boss monsters.
---@param ctx table|nil { instanceId, difficulty, playerIds }
---@return boolean, Monster[]
function BossLever:startEncounter(ctx)
	ctx = ctx or {}
	ctx.instanceId = tonumber(ctx.instanceId) or 0
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
			if ctx.instanceId == 0 then
				monster:registerEvent("BossLeverOnDeath")
			end
			self:scaleForm(monster, ctx)
			spawned[#spawned + 1] = monster
		end
		return true
	end
	local ok
	if ctx.instanceId ~= 0 and Game.runInInstance then
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

---@param instanceId number
---@return table|nil
function BossLever:encounterContext(instanceId)
	return self.encounters[tonumber(instanceId) or 0]
end

---@param instanceId number
function BossLever:clearEncounter(instanceId)
	self.encounters[tonumber(instanceId) or 0] = nil
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
---@param instanceId number
---@return Monster|nil
function BossLever:spawnForm(name, position, instanceId)
	local ctx = self:encounterContext(instanceId) or { instanceId = tonumber(instanceId) or 0 }
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
---@param instanceId number
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

---@param Zone
function BossLever:getZone()
	return Zone("boss." .. toKey(self.name))
end

---@param self BossLever
---@return boolean
function BossLever:register()
	local missingParams = {}
	if not self.name then
		table.insert(missingParams, "boss.name")
	end
	if not self.playerPositions then
		table.insert(missingParams, "playerPositions")
	end
	if not self.area then
		table.insert(missingParams, "specPos")
	end
	if not self.exit then
		table.insert(missingParams, "exit")
	end
	if not self._position and not self._uid and not self._aid then
		table.insert(missingParams, "position or uid or aid")
	end
	if #missingParams > 0 then
		local name = self.name or "unknown"
		logger.error("BossLever:register() - boss with name {} missing parameters: {}", name, table.concat(missingParams, ", "))
		return false
	end

	local zone = self:getZone()

	zone:addArea(self.area.from, self.area.to)
	for _, extra in ipairs(self.extraAreas) do
		zone:addArea(extra.from, extra.to)
	end
	zone:blockFamiliars()
	zone:setRemoveDestination(self.exit)

	local action = Action()
	action.onUse = function(player)
		self:onUse(player)
	end
	if self._position then
		action:position(self._position)
	end
	if self._uid then
		action:uid(self._uid)
	end
	if self._aid then
		action:aid(self._aid)
	end
	action:register()
	BossLever[self.name] = self

	if self.exitTeleporter then
		SimpleTeleport(self.exitTeleporter, self.exit)
	end
	return true
end
