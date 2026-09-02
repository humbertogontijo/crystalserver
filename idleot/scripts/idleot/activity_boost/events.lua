-- Activity Boost: daily activities, XP boost bank, world bosses (opcode 125).

logger.info("[ActivityBoost] ready (opcode {})", ActivityBoostConfig and ActivityBoostConfig.OPCODE or 125)

local loginEvent = CreatureEvent("ActivityBoostLogin")

function loginEvent.onLogin(player)
	player:registerEvent("ActivityBoostOpcode")
	if ActivityBoostActivities and ActivityBoostActivities.onLogin then
		pcall(ActivityBoostActivities.onLogin, player)
	end
	addEvent(function()
		local p = Player(player:getId())
		if p and ActivityBoostProtocol and ActivityBoostProtocol.sendState then
			ActivityBoostProtocol.sendState(p)
		end
	end, 1500)
	return true
end

loginEvent:register()

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
	if ActivityBoostWorldBoss and ActivityBoostWorldBoss.onBossDeath then
		pcall(ActivityBoostWorldBoss.onBossDeath, creature)
	end
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

local saveEvent = GlobalEvent("ActivityBoostSave")

function saveEvent.onSave()
	if ActivityBoostActivities and ActivityBoostActivities.onServerSave then
		pcall(ActivityBoostActivities.onServerSave)
	end
	if ActivityBoostWorldBoss and ActivityBoostWorldBoss.onServerSave then
		pcall(ActivityBoostWorldBoss.onServerSave)
	end
	return true
end

saveEvent:register()

local think = GlobalEvent("ActivityBoostThink")

function think.onThink(interval)
	for _, player in ipairs(Game.getPlayers()) do
		pcall(function()
			if ActivityBoostLedger and ActivityBoostLedger.reconcileWithEngine then
				ActivityBoostLedger.reconcileWithEngine(player)
			end
		end)
	end
	if ActivityBoostWorldBoss and ActivityBoostWorldBoss.tick then
		pcall(ActivityBoostWorldBoss.tick)
	end
	return true
end

think:interval(60000)
think:register()

local startup = GlobalEvent("ActivityBoostWorldBossStartup")

function startup.onStartup()
	if ActivityBoostWorldBoss and ActivityBoostWorldBoss.ensureAllBands then
		pcall(ActivityBoostWorldBoss.ensureAllBands)
	end
	return true
end

startup:register()

-- Optional daily refresh at configured clock times (rotates bosses).
local function registerWorldBossClock(index, clock)
	local ev = GlobalEvent("ActivityBoostWorldBossSession" .. tostring(index))
	function ev.onTime(interval)
		if ActivityBoostWorldBoss and ActivityBoostWorldBoss.startSession then
			ActivityBoostWorldBoss.startSession(index)
		end
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
