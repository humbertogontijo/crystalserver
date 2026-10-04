local loginEvent = CreatureEvent("ExpeditionLogin")

function loginEvent.onLogin(player)
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
	pcall(function()
		ExpeditionManager.onDeath(player)
	end)
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

local monsterDeath = CreatureEvent("ExpeditionMonsterDeath")

function monsterDeath.onDeath(creature, corpse, killer, mostDamageKiller, lastHitUnjustified, mostDamageUnjustified)
	local arenaHandled = false
	if QuestArena and QuestArena.handleMonsterDeath then
		pcall(function()
			arenaHandled = QuestArena.handleMonsterDeath(creature, corpse) == true
		end)
	end
	if not arenaHandled then
		pcall(function()
			ExpeditionPack.onMonsterDeath(creature, corpse)
		end)
	end
	-- Soul Pit expedition waves (not owned by ExpeditionPack).
	if SoulPitExpedition and SoulPitExpedition.onMonsterDeath and ExpeditionManager then
		pcall(function()
			local handled = false
			if type(onDeathForParty) == "function" then
				onDeathForParty(creature, mostDamageKiller, function(_, player)
					if handled then
						return
					end
					local session = ExpeditionManager.getSessionByPlayer(player)
					if session and session.kind == "soulpit" then
						handled = true
						SoulPitExpedition.onMonsterDeath(session)
					end
				end)
			end
		end)
	end
	-- Idle Quests & Tasks: credit Spike / Dragon Hunt (stock scripts are map-gated).
	if QuestsManager and QuestsManager.onMonsterKill then
		pcall(function()
			local name = creature:getName()
			onDeathForParty(creature, mostDamageKiller, function(_, player)
				QuestsManager.onMonsterKill(player, name)
			end)
		end)
	end
	return true
end

monsterDeath:register()

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
	-- Session AI is only ExpeditionAI.start's aiEvent — do not call ExpeditionAI.tick here.
	pcall(CombatAutomation.onThink, player, interval)
	pcall(ExpeditionManager.syncSessionClientIfNeeded, player)
end

thinkCallback:register()

-- Immediate eject when a player leaves the expedition/raid zone (e.g. GM teleport).
local zoneLeaveCallback = EventCallback("ExpeditionZoneAfterLeave")

function zoneLeaveCallback.zoneAfterCreatureLeave(zone, creature)
	local player = creature and creature:getPlayer()
	if not player or not ExpeditionManager or not ExpeditionManager.getSessionByPlayer then
		return
	end
	local session = ExpeditionManager.getSessionByPlayer(player)
	if not session or not session.entered or session.reconciling then
		return
	end
	local instZone = session.instance and session.instance.zone
	if not instZone or instZone ~= zone then
		return
	end
	pcall(function()
		ExpeditionManager.reconcilePresence(player)
	end)
end

zoneLeaveCallback:register()

local startup = GlobalEvent("ExpeditionStartup")

function startup.onStartup()
	ExpeditionManager.onStartup()
	RaidInstance.onStartup()
	return true
end

startup:register()

local saveEvent = GlobalEvent("ExpeditionSave")

function saveEvent.onSave()
	pcall(ExpeditionManager.onServerSave)
	return true
end

saveEvent:register()
