-- ============================================================================
-- Echo Warden Trigger - onDeath for bestiary monsters (stars 1-5)
-- (a) chance to spawn echo portal at corpse (instance-bound)
-- (b) Echo Warden death -> first-kill charms for every damaging participant
-- ============================================================================

local echoWardenTrigger = CreatureEvent("EchoWardenTrigger")

-- summon-aware list of players who damaged the creature
local function damagersOf(creature)
	local players, seen = {}, {}
	local dmap = creature:getDamageMap()
	if not dmap then
		return players
	end
	for cid, _ in pairs(dmap) do
		if cid and cid > 0 then
			local d = Creature(cid)
			if d then
				local pl
				if d:isPlayer() then
					pl = d:getPlayer()
				else
					local master = d:getMaster()
					if master and master:isPlayer() then
						pl = master:getPlayer()
					end
				end
				if pl and not seen[pl:getId()] then
					seen[pl:getId()] = true
					players[#players + 1] = pl
				end
			end
		end
	end
	return players
end

function echoWardenTrigger.onDeath(creature, corpse, killer, mostDamageKiller, lastHitUnjustified, mostDamageUnjustified)
	if not creature or not creature:isMonster() then
		return true
	end

	-- (b) tagged Echo Warden -> forge dust + first-kill charm per damager.
	if creature:getStorageValue(EchoWarden.STORAGE_IS_WARDEN) == 1 then
		local baseKind = EchoWarden.activeWardens[creature:getId()] or creature:getName()
		EchoWarden.activeWardens[creature:getId()] = nil
		local dustPlayer
		if mostDamageKiller then
			if mostDamageKiller:isPlayer() then
				dustPlayer = mostDamageKiller:getPlayer()
			else
				local master = mostDamageKiller:getMaster()
				if master and master:isPlayer() then
					dustPlayer = master:getPlayer()
				end
			end
		end
		if not dustPlayer and killer then
			if killer:isPlayer() then
				dustPlayer = killer:getPlayer()
			else
				local master = killer:getMaster()
				if master and master:isPlayer() then
					dustPlayer = master:getPlayer()
				end
			end
		end
		if dustPlayer then
			EchoWarden.grantDust(dustPlayer)
		end
		for _, player in ipairs(damagersOf(creature)) do
			EchoWarden.grantReward(player, baseKind)
		end
	end

	local mType = creature:getType()
	if not mType then
		return true
	end

	-- Guards: never spawn from summon / reward boss / bosstiary boss / forge.
	if creature:getMaster() ~= nil or mType:isRewardBoss() then
		return true
	end
	local br = mType.bossRace and mType:bossRace()
	if br and br ~= "" then
		return true
	end
	if creature.getForgeStack and creature:getForgeStack() > 0 then
		return true
	end
	local stars = mType:BestiaryStars() or 0
	-- Product: any bestiary creature (1-5★). Skip unset/non-bestiary (0).
	if stars < 1 or stars > 5 then
		return true
	end

	-- (a) portal spawn roll (includes echo-raid packs; wiki does not exclude them)
	if math.random(1, EchoWarden.SPAWN_CHANCE_DEN) > EchoWarden.SPAWN_CHANCE_NUM then
		return true
	end

	local kindName = creature:getName()
	local pos = creature:getPosition()
	local instanceId = EchoWarden.creatureInstanceId(creature)
	logger.info(
		"[EchoWarden] portal armed kind={} stars={} instance={} at {},{},{}",
		kindName,
		stars,
		instanceId,
		pos.x,
		pos.y,
		pos.z
	)
	EchoWarden.spawnPortal(pos.x, pos.y, pos.z, kindName, instanceId)

	return true
end

echoWardenTrigger:register()

-- Register the death event to bestiary monsters at boot (stars 1-5).
local echoWardenStartup = GlobalEvent("EchoWardenTriggerStartup")

function echoWardenStartup.onStartup()
	local count = 0
	for stars = 1, 5 do
		local monsters = Game.getMonstersByBestiaryStars(stars)
		if monsters then
			for _, mType in ipairs(monsters) do
				if mType:name() then
					mType:registerEvent("EchoWardenTrigger")
					count = count + 1
				end
			end
		end
	end
	logger.info("[EchoWarden] Registered death trigger to {} monsters (bestiary 1-5★)", count)
	return true
end

echoWardenStartup:register()
