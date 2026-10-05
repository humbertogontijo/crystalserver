-- Make Believe Quest finale: Phosphorus flees at 0 HP, Maior Domus (Final) and Mimar Haffar
-- (Final) are fought together in the second arena, then Phosphorus (Final) in the third.
local ARENA = {
	phosphorus = {
		boss = Position(33807, 32751, 15),
		players = Position(33807, 32758, 15),
	},
	council = {
		maiorDomus = Position(33739, 32690, 15),
		mimarHaffar = Position(33747, 32690, 15),
		players = Position(33743, 32697, 15),
	},
	final = {
		boss = Position(33871, 32749, 15),
		players = Position(33871, 32756, 15),
	},
}
local PHASE_DELAY_MS = 3000

local config = {
	boss = {
		name = "Phosphorus",
		position = ARENA.phosphorus.boss,
		createFunction = function()
			local monster = Game.createMonster("Phosphorus", ARENA.phosphorus.boss, true, true)
			if not monster then
				return false
			end
			monster:registerEvent("PhosphorusFlee")
			return monster
		end,
	},
	finalBoss = "Phosphorus (Final)",
	difficulty = { max = 25 },
	requiredLevel = 250,
	timeToDefeat = 30 * 60,
	playerPositions = {
		{ pos = Position(33805, 32690, 15), teleport = ARENA.phosphorus.players, effect = CONST_ME_TELEPORT },
		{ pos = Position(33806, 32690, 15), teleport = ARENA.phosphorus.players, effect = CONST_ME_TELEPORT },
		{ pos = Position(33807, 32690, 15), teleport = ARENA.phosphorus.players, effect = CONST_ME_TELEPORT },
		{ pos = Position(33808, 32690, 15), teleport = ARENA.phosphorus.players, effect = CONST_ME_TELEPORT },
		{ pos = Position(33809, 32690, 15), teleport = ARENA.phosphorus.players, effect = CONST_ME_TELEPORT },
	},
	specPos = {
		from = Position(33793, 32737, 15),
		to = Position(33822, 32766, 15),
	},
	extraAreas = {
		{ from = Position(33730, 32681, 15), to = Position(33756, 32701, 15) },
		{ from = Position(33859, 32743, 15), to = Position(33884, 32760, 15) },
	},
	exit = Position(33972, 32632, 6),
}

local lever = BossLever(config)
lever:position(Position(33810, 32690, 15))
lever:register()

local function inEncounter(instanceId, fn)
	if instanceId ~= 0 then
		return Game.runInInstance(instanceId, fn)
	end
	return fn()
end

local function inArena(pos)
	for _, rect in ipairs({ config.specPos, config.extraAreas[1], config.extraAreas[2] }) do
		if pos.z == rect.from.z and pos.x >= rect.from.x and pos.x <= rect.to.x and pos.y >= rect.from.y and pos.y <= rect.to.y then
			return true
		end
	end
	return false
end

local function encounterPlayers(instanceId)
	local players = {}
	for _, player in ipairs(Game.getPlayers()) do
		if player:getInstanceId() == instanceId and inArena(player:getPosition()) then
			players[#players + 1] = player
		end
	end
	return players
end

local function movePlayers(instanceId, destination)
	local players = encounterPlayers(instanceId)
	inEncounter(instanceId, function()
		for _, player in ipairs(players) do
			player:teleportTo(destination)
		end
		destination:sendMagicEffect(CONST_ME_TELEPORT)
	end)
	return #players > 0
end

local councilAlive = {}

local function startFinal(instanceId)
	if not movePlayers(instanceId, ARENA.final.players) then
		return
	end
	local monster = lever:spawnForm("Phosphorus (Final)", ARENA.final.boss, instanceId)
	if monster and instanceId == 0 then
		monster:registerEvent("BossLeverOnDeath")
	end
end

local function startCouncil(instanceId)
	if not movePlayers(instanceId, ARENA.council.players) then
		return
	end
	councilAlive[instanceId] = 0
	for _, form in ipairs({ { "Maior Domus (Final)", ARENA.council.maiorDomus }, { "Mimar Haffar (Final)", ARENA.council.mimarHaffar } }) do
		local monster = lever:spawnForm(form[1], form[2], instanceId)
		if monster then
			monster:registerEvent("PhosphorusCouncilDeath")
			councilAlive[instanceId] = councilAlive[instanceId] + 1
		end
	end
end

local fled = {}

local function flee(monsterId)
	fled[monsterId] = nil
	local monster = Monster(monsterId)
	if not monster then
		return
	end
	local instanceId = monster:getInstanceId()
	inEncounter(instanceId, function()
		monster:getPosition():sendMagicEffect(CONST_ME_POFF)
		monster:remove()
	end)
	addEvent(startCouncil, PHASE_DELAY_MS, instanceId)
end

local phosphorusFlee = CreatureEvent("PhosphorusFlee")

function phosphorusFlee.onHealthChange(creature, attacker, primaryDamage, primaryType, secondaryDamage, secondaryType, origin)
	if not creature or primaryType == COMBAT_HEALING then
		return primaryDamage, primaryType, secondaryDamage, secondaryType
	end
	local id = creature:getId()
	if fled[id] then
		return 0, primaryType, 0, secondaryType
	end
	local health = creature:getHealth()
	if health - primaryDamage - secondaryDamage > 0 then
		return primaryDamage, primaryType, secondaryDamage, secondaryType
	end
	fled[id] = true
	creature:say("You will never catch me!", TALKTYPE_MONSTER_YELL)
	addEvent(flee, 0, id)
	return math.max(0, health - 1), primaryType, 0, secondaryType
end

phosphorusFlee:register()

local councilDeath = CreatureEvent("PhosphorusCouncilDeath")

function councilDeath.onDeath(creature)
	local instanceId = creature:getInstanceId()
	local left = (councilAlive[instanceId] or 1) - 1
	if left > 0 then
		councilAlive[instanceId] = left
		return true
	end
	councilAlive[instanceId] = nil
	addEvent(startFinal, PHASE_DELAY_MS, instanceId)
	return true
end

councilDeath:register()
