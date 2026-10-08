local loginEvent = CreatureEvent("ExpeditionLogin")

function loginEvent.onLogin(player)
	-- Opcode 113 also carries the combat automation config (get/setAutomation).
	player:registerEvent("ExpeditionExtendedOpcode")
	local ok, err = pcall(function()
		ExpeditionManager.onLogin(player)
	end)
	if not ok then
		logger.error("[Expedition] onLogin failed for {}: {}", player:getName(), err)
	end
	return true
end

loginEvent:register()

local opcodeEvent = CreatureEvent("ExpeditionExtendedOpcode")

function opcodeEvent.onExtendedOpcode(player, opcode, buffer)
	if not ExpeditionConfig or opcode ~= ExpeditionConfig.OPCODE then
		return
	end
	local ok, err = pcall(function()
		ExpeditionProtocol.handle(player, buffer)
	end)
	if not ok then
		logger.error("[Expedition] opcode handler failed: {}", err)
	end
end

opcodeEvent:register()

local deathEvent = CreatureEvent("ExpeditionPlayerDeath")

function deathEvent.onDeath(player, corpse, killer, mostDamageKiller, lastHitUnjustified, mostDamageUnjustified)
	IdleSafe.call("ExpeditionManager.onDeath", ExpeditionManager.onDeath, player)
	return true
end

deathEvent:register()

local logoutEvent = CreatureEvent("ExpeditionPlayerLogout")

function logoutEvent.onLogout(player)
	local ok, result = pcall(function()
		return ExpeditionManager.onLogout(player)
	end)
	if not ok then
		logger.error("[Expedition] onLogout failed for {}: {}", player:getName(), result)
		return true
	end
	if result == false then
		return false
	end
	return true
end

logoutEvent:register()

-- Instance copies of world spawns (Game.createInstanceSpawns) → lure-hunt tracking.
local monsterSpawnCallback = EventCallback("ExpeditionMonsterOnSpawn")

function monsterSpawnCallback.monsterOnSpawn(monster, position)
	if ExpeditionPack and ExpeditionPack.onInstanceMonsterSpawn then
		local ok, err = pcall(ExpeditionPack.onInstanceMonsterSpawn, monster, position)
		if not ok then
			logger.error("[Expedition] monsterOnSpawn failed: {}", err)
		end
	end
end

monsterSpawnCallback:register()

local thinkCallback = EventCallback("CombatAutomationPlayerOnThink")

function thinkCallback.playerOnThink(player, interval)
	-- Engine think owns per-player combat cadence (idleCombat 250ms).
	-- Session AI is only ExpeditionAI.start's scope loop — do not call ExpeditionAI.tick here.
	IdleSafe.call("PlayerErrand.think", PlayerErrand.think, player)
	IdleSafe.call("CombatAutomation.onThink", CombatAutomation.onThink, player, interval)
	IdleSafe.call("ExpeditionManager.syncSessionClientIfNeeded", ExpeditionManager.syncSessionClientIfNeeded, player)
end

thinkCallback:register()

local startup = GlobalEvent("ExpeditionStartup")

function startup.onStartup()
	ExpeditionManager.onStartup()
	RaidInstance.onStartup()
	return true
end

startup:register()
