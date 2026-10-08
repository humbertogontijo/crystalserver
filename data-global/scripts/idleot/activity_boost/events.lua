-- Activity Boost: daily activities, XP boost bank, world bosses (opcode 125).

logger.info("[ActivityBoost] ready (opcode {})", ActivityBoostConfig.OPCODE or 125)

local loginEvent = CreatureEvent("ActivityBoostLogin")

function loginEvent.onLogin(player)
	player:registerEvent("ActivityBoostOpcode")
	IdleSafe.call("ActivityBoostActivities.onLogin", ActivityBoostActivities.onLogin, player)
	return true
end

loginEvent:register()

local clientReadyCallback = EventCallback("ActivityBoostPlayerOnClientReady")

function clientReadyCallback.playerOnClientReady(player)
	ActivityBoostProtocol.sendState(player)
end

clientReadyCallback:register()

local bountyCallback = EventCallback("ActivityBoostPlayerOnBountyTaskClaimed")

function bountyCallback.playerOnBountyTaskClaimed(player)
	ActivityBoostActivities.onBountyTaskClaimed(player)
end

bountyCallback:register()

local logoutEvent = CreatureEvent("ActivityBoostLogout")

function logoutEvent.onLogout(player)
	ActivityBoostActivities.onLogout(player)
	return true
end

logoutEvent:register()

local killCallback = EventCallback("ActivityBoostDailyHuntKill")

function killCallback.playerOnKilledMonster(player, monster)
	ActivityBoostActivities.onKilledMonster(player, monster)
end

killCallback:register()

local opcodeEvent = CreatureEvent("ActivityBoostOpcode")

function opcodeEvent.onExtendedOpcode(player, opcode, buffer)
	if opcode ~= ActivityBoostConfig.OPCODE then
		return
	end
	local ok, err = pcall(function()
		ActivityBoostProtocol.handle(player, buffer)
	end)
	if not ok then
		logger.error("[ActivityBoost] opcode handler failed: {}", err)
	end
end

opcodeEvent:register()

local bossHealth = CreatureEvent("ActivityBoostWorldBossHealth")

function bossHealth.onHealthChange(creature, attacker, primaryDamage, primaryType, secondaryDamage, secondaryType, origin)
	return ActivityBoostWorldBoss.onHealthChange(
		creature,
		attacker,
		primaryDamage,
		primaryType,
		secondaryDamage,
		secondaryType,
		origin
	)
end

bossHealth:register()

local think = GlobalEvent("ActivityBoostThink")

function think.onThink(interval)
	for _, player in ipairs(Game.getPlayers()) do
		IdleSafe.call("ActivityBoostLedger.reconcileWithEngine", ActivityBoostLedger.reconcileWithEngine, player)
	end
	return true
end

think:interval(60000)
think:register()

local startup = GlobalEvent("ActivityBoostWorldBossStartup")

function startup.onStartup()
	IdleSafe.call("ActivityBoostWorldBoss.ensureAllBands", ActivityBoostWorldBoss.ensureAllBands)
	return true
end

startup:register()

-- Optional daily refresh at configured clock times (rotates bosses).
local function registerWorldBossClock(index, clock)
	local ev = GlobalEvent("ActivityBoostWorldBossSession" .. tostring(index))
	function ev.onTime(interval)
		ActivityBoostWorldBoss.startSession(index)
		return true
	end
	ev:time(clock)
	ev:register()
end

do
	local times = (ActivityBoostConfig.WORLD_BOSS_SESSION_TIMES) or { "12:00", "20:00" }
	for index, clock in ipairs(times) do
		registerWorldBossClock(index, clock)
	end
end
