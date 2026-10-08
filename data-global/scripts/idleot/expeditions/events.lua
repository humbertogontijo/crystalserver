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
	if opcode ~= ExpeditionConfig.OPCODE then
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
	local ok, err = pcall(ExpeditionPack.onInstanceMonsterSpawn, monster, position)
	if not ok then
		logger.error("[Expedition] monsterOnSpawn failed: {}", err)
	end
end

monsterSpawnCallback:register()

-- Engine think owns per-player combat cadence: playerOnIdleCombatThink (250ms) while idle
-- combat runs, playerOnThink (1s) otherwise. Session AI is only ExpeditionAI.start's scope
-- loop — do not call ExpeditionAI.tick here.
local function automationThink(player, interval)
	IdleSafe.call("PlayerErrand.think", PlayerErrand.think, player)
	IdleSafe.call("CombatAutomation.onThink", CombatAutomation.onThink, player, interval)
end

local idleCombatThinkCallback = EventCallback("CombatAutomationPlayerOnIdleCombatThink")

function idleCombatThinkCallback.playerOnIdleCombatThink(player, interval)
	automationThink(player, interval)
end

idleCombatThinkCallback:register()

local thinkCallback = EventCallback("CombatAutomationPlayerOnThink")

function thinkCallback.playerOnThink(player, interval)
	if not player:isIdleCombat() then
		automationThink(player, interval)
	end
end

thinkCallback:register()

local clientReadyCallback = EventCallback("ExpeditionPlayerOnClientReady")

function clientReadyCallback.playerOnClientReady(player)
	IdleSafe.call("ExpeditionManager.syncSessionClientIfNeeded", ExpeditionManager.syncSessionClientIfNeeded, player)
end

clientReadyCallback:register()

local clientDetachCallback = EventCallback("ExpeditionPlayerOnClientDetach")

function clientDetachCallback.playerOnClientDetach(player)
	ExpeditionManager.onClientDetached(player)
end

clientDetachCallback:register()

local bossDifficultyCallback = EventCallback("BossDifficultyPlayerOnSelection")

-- action: 0 = start, 1 = cancel, 2 = spinner preview.
function bossDifficultyCallback.playerOnBossDifficulty(player, action, difficulty, _selectionContext)
	if action == 0 then
		BossDifficulty.onStart(player, difficulty)
	elseif action == 2 then
		BossDifficulty.onPreview(player, difficulty)
	else
		BossDifficulty.onCancel(player)
	end
end

bossDifficultyCallback:register()

local startup = GlobalEvent("ExpeditionStartup")

function startup.onStartup()
	ExpeditionManager.onStartup()
	RaidInstance.onStartup()
	return true
end

startup:register()
