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
			ExpeditionWaves.onMonsterDeath(creature, corpse)
		end)
	end
	-- Soul Pit expedition waves (not tracked in ExpeditionWaves.monsterOwners).
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
	if ExpeditionWaves and ExpeditionWaves.onInstanceMonsterSpawn then
		local ok, err = pcall(ExpeditionWaves.onInstanceMonsterSpawn, monster, position)
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
	if CombatAutomation and CombatAutomation.onThink then
		pcall(CombatAutomation.onThink, player, interval)
	end
	-- Player attack packets can change the server target between AI ticks; keep the
	-- client red square in sync (vanilla has no S→C attack opcode).
	if ExpeditionManager.getSessionByPlayer and ExpeditionAI and ExpeditionAI.syncAttackTargetIfChanged then
		local session = ExpeditionManager.getSessionByPlayer(player)
		if session and session.entered and session.state ~= "ended" then
			pcall(ExpeditionAI.syncAttackTargetIfChanged, session, player)
		end
	end
	if ExpeditionManager and ExpeditionManager.syncSessionClientIfNeeded then
		pcall(ExpeditionManager.syncSessionClientIfNeeded, player)
	end
end

thinkCallback:register()

-- Familiar-style companion catch-up: yank on the anchor's step (Player::onWalk → playerOnWalk).
local walkCallback = EventCallback("ExpeditionPlayerOnWalk")

function walkCallback.playerOnWalk(player, _dir)
	if ExpeditionAI and ExpeditionAI.onPlayerWalk then
		pcall(ExpeditionAI.onPlayerWalk, player)
	end
end

walkCallback:register()

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
	if ExpeditionManager and ExpeditionManager.onStartup then
		ExpeditionManager.onStartup()
	end
	if RaidInstance and RaidInstance.onStartup then
		RaidInstance.onStartup()
	end
	return true
end

startup:register()

local saveEvent = GlobalEvent("ExpeditionSave")

function saveEvent.onSave()
	if ExpeditionManager and ExpeditionManager.onServerSave then
		pcall(ExpeditionManager.onServerSave)
	end
	return true
end

saveEvent:register()
