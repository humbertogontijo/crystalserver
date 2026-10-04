-- Activity Boost: daily activities, XP boost bank, world bosses (opcode 125).

logger.info("[ActivityBoost] ready (opcode {})", ActivityBoostConfig and ActivityBoostConfig.OPCODE or 125)

local loginEvent = CreatureEvent("ActivityBoostLogin")

function loginEvent.onLogin(player)
	player:registerEvent("ActivityBoostOpcode")
	player:registerEvent("ActivityBoostLogout")
	pcall(ActivityBoostActivities.onLogin, player)
	addEvent(function()
		local p = Player(player:getId())
		if p and ActivityBoostProtocol and ActivityBoostProtocol.sendState then
			ActivityBoostProtocol.sendState(p)
		end
	end, 1500)
	return true
end

loginEvent:register()

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
	if not ActivityBoostConfig or opcode ~= ActivityBoostConfig.OPCODE then
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
	if ActivityBoostWorldBoss and ActivityBoostWorldBoss.onHealthChange then
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
	return primaryDamage, primaryType, secondaryDamage, secondaryType
end

bossHealth:register()

local bossDeath = CreatureEvent("ActivityBoostWorldBossDeath")

function bossDeath.onDeath(creature, corpse, killer, mostDamageKiller, lastHitUnjustified, mostDamageUnjustified)
	pcall(ActivityBoostWorldBoss.onBossDeath, creature)
	return true
end

bossDeath:register()

local playerHealth = CreatureEvent("ActivityBoostWorldBossPlayerHealth")

function playerHealth.onHealthChange(creature, attacker, primaryDamage, primaryType, secondaryDamage, secondaryType, origin)
	if ActivityBoostWorldBoss and ActivityBoostWorldBoss.onPlayerHealthChange then
		return ActivityBoostWorldBoss.onPlayerHealthChange(
			creature,
			attacker,
			primaryDamage,
			primaryType,
			secondaryDamage,
			secondaryType,
			origin
		)
	end
	return primaryDamage, primaryType, secondaryDamage, secondaryType
end

playerHealth:register()

local prepareDeath = CreatureEvent("ActivityBoostWorldBossPrepareDeath")

function prepareDeath.onPrepareDeath(creature, killer)
	local player = creature and creature:getPlayer()
	if player and ActivityBoostWorldBoss and ActivityBoostWorldBoss.onPlayerPrepareDeath then
		return ActivityBoostWorldBoss.onPlayerPrepareDeath(player)
	end
	return true
end

prepareDeath:register()

local think = GlobalEvent("ActivityBoostThink")

function think.onThink(interval)
	for _, player in ipairs(Game.getPlayers()) do
		pcall(function()
			ActivityBoostLedger.reconcileWithEngine(player)
		end)
	end
	pcall(ActivityBoostWorldBoss.tick)
	return true
end

think:interval(60000)
think:register()

local startup = GlobalEvent("ActivityBoostWorldBossStartup")

function startup.onStartup()
	pcall(ActivityBoostWorldBoss.ensureAllBands)
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
	local times = (ActivityBoostConfig and ActivityBoostConfig.WORLD_BOSS_SESSION_TIMES) or { "12:00", "20:00" }
	for index, clock in ipairs(times) do
		registerWorldBossClock(index, clock)
	end
end
