ActivityBoostWorldBoss = ActivityBoostWorldBoss or {}

-- Active sessions keyed by band id (one fight per band arena).
ActivityBoostWorldBoss.active = ActivityBoostWorldBoss.active or {}
ActivityBoostWorldBoss.schedule = ActivityBoostWorldBoss.schedule or {}
-- Cooldown per band+boss so the same boss in another band stays available.
ActivityBoostWorldBoss.bossCooldownUntil = ActivityBoostWorldBoss.bossCooldownUntil or {}
-- Legacy alias (cleared on load so old band-wide locks do not linger).
ActivityBoostWorldBoss.bandCooldownUntil = ActivityBoostWorldBoss.bandCooldownUntil or {}

local function bandForLevel(level)
	level = tonumber(level) or 0
	for _, band in ipairs(ActivityBoostConfig.LEVEL_BANDS or {}) do
		if level >= (band.levelMin or 0) and level <= (band.levelMax or 99999) then
			return band
		end
	end
	return nil
end

local function lootMultForRank(rank)
	local table_ = ActivityBoostConfig.WORLD_BOSS_LOOT_MULT or {}
	local floor = ActivityBoostConfig.WORLD_BOSS_LOOT_MULT_FLOOR or 0.15
	return table_[rank] or floor
end

local function cooldownKey(bandId, bossName)
	return tostring(bandId) .. ":" .. tostring(bossName or "")
end

local function poolForBand(bandId)
	local pools = ActivityBoostConfig.WORLD_BOSS_POOLS or ActivityBoostConfig.WORLD_BOSS_BY_BAND or {}
	local pool = pools[bandId]
	if pool and #pool > 0 then
		return pool
	end
	return ActivityBoostConfig.WORLD_BOSS_SHORTLIST or {}
end

local function bossOnCooldown(bandId, bossName, now)
	now = now or os.time()
	local untilTs = ActivityBoostWorldBoss.bossCooldownUntil[cooldownKey(bandId, bossName)] or 0
	return untilTs > now, untilTs
end

local function pickBossName(bandId, sessionIndex)
	local list = poolForBand(bandId)
	if #list == 0 then
		return "Glooth Fairy"
	end
	local seed = (os.date("%Y%m%d") + 0)
	local bandHash = 0
	for i = 1, #tostring(bandId) do
		bandHash = bandHash + string.byte(tostring(bandId), i)
	end
	local idx = ((seed + bandHash * 17 + (sessionIndex or 0) * 31) % #list) + 1
	return list[idx]
end

local function firstAvailableBoss(bandId, now)
	now = now or os.time()
	for _, bossName in ipairs(poolForBand(bandId)) do
		local onCd = bossOnCooldown(bandId, bossName, now)
		if not onCd then
			return bossName
		end
	end
	return nil
end

local function bossInBandPool(bandId, bossName)
	if type(bossName) ~= "string" or bossName == "" then
		return false
	end
	for _, name in ipairs(poolForBand(bandId)) do
		if name == bossName then
			return true
		end
	end
	return false
end

local function creatureIdForBossName(bossName)
	if type(bossName) ~= "string" or bossName == "" then
		return nil
	end
	local mType = MonsterType(bossName)
	if mType and mType.raceId then
		local id = mType:raceId()
		if type(id) == "number" and id > 0 then
			return id
		end
	end
	if ExpeditionConfig and ExpeditionConfig.Catalog then
		local key = bossName:lower()
		for _, entry in ipairs(ExpeditionConfig.Catalog) do
			if entry.name and tostring(entry.name):lower() == key then
				local id = tonumber(entry.creatureId) or tonumber(entry.bossRaceId)
				if id and id > 0 then
					return id
				end
			end
		end
	end
	return nil
end

local function isFraggedToday(player)
	if ActivityBoostActivities and ActivityBoostActivities.worldBossCapReached then
		return ActivityBoostActivities.worldBossCapReached(player)
	end
	return false
end

local function noteWorldBossFrag(player)
	if ActivityBoostActivities and ActivityBoostActivities.addProgress then
		ActivityBoostActivities.addProgress(player, "world_boss", 1)
	end
end

local function partyLeaderKey(player)
	if not player then
		return nil
	end
	local party = player.getParty and player:getParty()
	if party and party.getLeader then
		local leader = party:getLeader()
		if leader then
			return "party:" .. leader:getGuid(), leader:getName(), true
		end
	end
	return "solo:" .. player:getGuid(), player:getName(), false
end

local function meterList(session)
	local rows = {}
	for key, entry in pairs(session.damage or {}) do
		rows[#rows + 1] = {
			key = key,
			name = entry.name,
			damage = entry.damage or 0,
			isParty = entry.isParty and true or false,
			memberGuids = entry.memberGuids or {},
		}
	end
	table.sort(rows, function(a, b)
		if a.damage ~= b.damage then
			return a.damage > b.damage
		end
		return tostring(a.name) < tostring(b.name)
	end)
	for i, row in ipairs(rows) do
		row.rank = i
		row.lootMult = lootMultForRank(i)
	end
	return rows
end

local function broadcastMeter(session)
	local ranking = meterList(session)
	local payload = {
		type = "worldBossMeter",
		band = session.bandId,
		bossName = session.bossName,
		ranking = ranking,
	}
	for _, pid in ipairs(session.playerIds or {}) do
		local p = Player(pid)
		if p and ActivityBoostProtocol and ActivityBoostProtocol.send then
			ActivityBoostProtocol.send(p, payload)
		end
	end
end

local function rollLootForPlayer(player, bossName, mult)
	local mType = MonsterType(bossName)
	if not mType or not mType.getLoot then
		return
	end
	local loot = mType:getLoot()
	if type(loot) ~= "table" then
		return
	end
	mult = tonumber(mult) or 1
	local given = {}
	for _, block in ipairs(loot) do
		local chance = math.floor((tonumber(block.chance) or 0) * mult)
		if chance > 0 and math.random(1, 100000) <= chance then
			local itemId = tonumber(block.itemId)
			if itemId and itemId > 0 then
				local minC = math.max(1, tonumber(block.minCount) or 1)
				local maxC = math.max(minC, tonumber(block.maxCount) or minC)
				local count = math.random(minC, maxC)
				local item = player:addItem(itemId, count)
				if item then
					given[#given + 1] = string.format("%dx %s", count, ItemType(itemId):getName())
				end
			end
		end
	end
	if #given > 0 then
		player:sendTextMessage(
			MESSAGE_LOOT,
			"World boss loot: " .. table.concat(given, ", ")
		)
	else
		player:sendTextMessage(MESSAGE_EVENT_ADVANCE, "World boss loot: nothing this time.")
	end
end

local function teardownSession(session, reason)
	if not session or session.tearingDown then
		return
	end
	session.tearingDown = true
	if session.bossCreatureId then
		local monster = Monster(session.bossCreatureId)
		if monster then
			if monster.setDropLoot then
				monster:setDropLoot(false)
			end
			monster:remove()
		end
		session.bossCreatureId = nil
	end
	local playerIds = session.playerIds or {}
	for _, pid in ipairs(playerIds) do
		local p = Player(pid)
		if p then
			ActivityBoostWorldBoss.leave(p, { silent = true, force = true, reason = reason })
		end
	end
	if session.instance then
		if ExpeditionInstance and ExpeditionInstance.teardown then
			ExpeditionInstance.teardown(session.instance)
		elseif session.instance.instanceId and ExpeditionInstance and ExpeditionInstance.free then
			ExpeditionInstance.free(session.instance.instanceId)
		end
	end
	ActivityBoostWorldBoss.active[session.bandId] = nil
	ActivityBoostWorldBoss.broadcastSchedule()
end

function ActivityBoostWorldBoss.listActive()
	local out = {}
	for _, session in pairs(ActivityBoostWorldBoss.active) do
		if session and not session.tearingDown then
			local band = nil
			for _, b in ipairs(ActivityBoostConfig.LEVEL_BANDS or {}) do
				if b.id == session.bandId then
					band = b
					break
				end
			end
			out[#out + 1] = {
				band = session.bandId,
				bandName = band and band.name or session.bandId,
				levelMin = band and band.levelMin or 0,
				levelMax = band and band.levelMax or 9999,
				bossName = session.bossName,
				creatureId = creatureIdForBossName(session.bossName),
				startedAt = session.startedAt,
				endsAt = session.endsAt,
				joinUntil = session.joinUntil,
				players = #(session.playerIds or {}),
				joinable = not session.bossDead
					and not session.tearingDown
					and not bossOnCooldown(session.bandId, session.bossName, os.time()),
			}
		end
	end
	table.sort(out, function(a, b)
		return (a.levelMin or 0) < (b.levelMin or 0)
	end)
	return out
end

local function nextUnixForClock(clock, now)
	now = now or os.time()
	local h, m = tostring(clock or ""):match("^(%d+):(%d+)$")
	h, m = tonumber(h), tonumber(m)
	if not h or not m then
		return nil
	end
	local t = os.date("*t", now)
	t.hour = h
	t.min = m
	t.sec = 0
	local at = os.time(t)
	if at <= now then
		at = at + 24 * 60 * 60
	end
	return at
end

--- Upcoming session slots sorted by soonest time.
local function upcomingSessions(now)
	now = now or os.time()
	local slots = {}
	for index, clock in ipairs(ActivityBoostConfig.WORLD_BOSS_SESSION_TIMES or {}) do
		local at = nextUnixForClock(clock, now)
		if at then
			slots[#slots + 1] = { index = index, clock = clock, at = at }
		end
	end
	table.sort(slots, function(a, b)
		return a.at < b.at
	end)
	return slots
end

--- One row per (band, boss). Same boss can appear in multiple bands.
function ActivityBoostWorldBoss.listSchedule()
	local now = os.time()
	local out = {}
	for _, band in ipairs(ActivityBoostConfig.LEVEL_BANDS or {}) do
		local session = ActivityBoostWorldBoss.active[band.id]
		local sessionLive = session
			and not session.tearingDown
			and not session.bossDead
		local pool = poolForBand(band.id)
		for _, bossName in ipairs(pool) do
			local onCooldown, cooldownUntil = bossOnCooldown(band.id, bossName, now)
			local isThisFight = sessionLive and session.bossName == bossName
			local otherFight = sessionLive and session.bossName ~= bossName
			local joinable = false
			local nextAt = 0
			local nextClock = ""
			if onCooldown then
				nextAt = cooldownUntil
				nextClock = "COOLDOWN"
			elseif isThisFight then
				nextAt = now
				nextClock = "NOW"
				joinable = true
			elseif otherFight then
				nextAt = session.endsAt or 0
				nextClock = "BUSY"
			else
				-- Arena free and boss off cooldown: join starts this fight.
				nextAt = now
				nextClock = "NOW"
				joinable = true
			end
			out[#out + 1] = {
				band = band.id,
				bandName = band.name,
				levelMin = band.levelMin or 0,
				levelMax = band.levelMax or 9999,
				bossName = bossName,
				creatureId = creatureIdForBossName(bossName),
				nextAt = nextAt,
				nextClock = nextClock,
				cooldownUntil = onCooldown and cooldownUntil or 0,
				active = isThisFight and true or false,
				joinable = joinable,
				players = isThisFight and #(session.playerIds or {}) or 0,
			}
		end
	end
	return out
end

--- Flat boss list (unique names) for legacy protocol consumers.
function ActivityBoostWorldBoss.listBossTimetable()
	local now = os.time()
	local seen = {}
	local out = {}
	for _, row in ipairs(ActivityBoostWorldBoss.listSchedule()) do
		if not seen[row.bossName] then
			seen[row.bossName] = true
			out[#out + 1] = {
				bossName = row.bossName,
				nextAt = row.nextAt or 0,
				nextClock = row.nextClock or "",
				band = row.band,
				bandName = row.bandName,
				levelMin = row.levelMin,
				levelMax = row.levelMax,
			}
		end
	end
	table.sort(out, function(a, b)
		if (a.nextAt or 0) == (b.nextAt or 0) then
			return tostring(a.bossName) < tostring(b.bossName)
		end
		return (a.nextAt or 0) < (b.nextAt or 0)
	end)
	return out
end

function ActivityBoostWorldBoss.broadcastSchedule()
	local payload = {
		type = "worldBossSchedule",
		active = ActivityBoostWorldBoss.listActive(),
		schedule = ActivityBoostWorldBoss.listSchedule(),
		bosses = ActivityBoostWorldBoss.listBossTimetable(),
		sessionTimes = ActivityBoostConfig.WORLD_BOSS_SESSION_TIMES or {},
	}
	for _, player in ipairs(Game.getPlayers()) do
		if ActivityBoostProtocol and ActivityBoostProtocol.send then
			ActivityBoostProtocol.send(player, payload)
		end
	end
end

local function startBandSession(band, bossName)
	if ActivityBoostWorldBoss.active[band.id] then
		teardownSession(ActivityBoostWorldBoss.active[band.id], "replaced")
	end
	bossName = bossName or firstAvailableBoss(band.id) or pickBossName(band.id, 0)
	if not bossName then
		return
	end
	local instanceId = ExpeditionInstance and ExpeditionInstance.allocate and ExpeditionInstance.allocate()
	if not instanceId then
		logger.error("[ActivityBoost] world boss: no instance for band {}", band.id)
		return
	end
	local arena = ActivityBoostConfig.WORLD_BOSS_ARENA or {}
	local buildOpts = {
		id = "worldboss_" .. band.id,
		region = "worldboss_" .. band.id,
		kind = "worldboss",
		center = arena.center,
		boundary = arena.boundary,
	}
	local instance, err = ExpeditionInstance.build(instanceId, buildOpts, os.time() + instanceId)
	if not instance then
		ExpeditionInstance.free(instanceId)
		logger.error("[ActivityBoost] world boss build failed {}: {}", band.id, err or "?")
		return
	end

	local now = os.time()
	local session = {
		bandId = band.id,
		bossName = bossName,
		instance = instance,
		playerIds = {},
		memberKeys = {},
		damage = {},
		playerDamage = {},
		knockoutUntil = {},
		startedAt = now,
		joinUntil = now + (ActivityBoostConfig.WORLD_BOSS_FIGHT_SEC or 1200),
		endsAt = now + (ActivityBoostConfig.WORLD_BOSS_FIGHT_SEC or 1200),
		bossCreatureId = nil,
		bossDead = false,
		tearingDown = false,
	}
	ActivityBoostWorldBoss.active[band.id] = session

	local spawnPos = Position(
		(arena.center and arena.center.x) or 33688,
		(arena.center and arena.center.y) or 31937,
		(arena.center and arena.center.z) or 9
	)
	if instance.entry then
		spawnPos = Position(instance.entry.x, instance.entry.y, instance.entry.z)
	end
	local monster = Game.createMonster(bossName, spawnPos, false, true)
	if monster then
		if monster.setInstanceId and instance.instanceId then
			monster:setInstanceId(instance.instanceId)
		end
		if monster.setDropLoot then
			monster:setDropLoot(false)
		end
		monster:registerEvent("ActivityBoostWorldBossHealth")
		monster:registerEvent("ActivityBoostWorldBossDeath")
		session.bossCreatureId = monster:getId()
	else
		logger.error("[ActivityBoost] failed to spawn world boss {}", bossName)
	end

	addEvent(function()
		local s = ActivityBoostWorldBoss.active[band.id]
		if s and not s.bossDead and not s.tearingDown then
			Game.broadcastMessage(
				string.format("World Boss (%s): time expired - %s escaped.", band.name, s.bossName or "boss"),
				MESSAGE_EVENT_ADVANCE
			)
			teardownSession(s, "timeout")
			addEvent(function()
				ActivityBoostWorldBoss.broadcastSchedule()
			end, 2000)
		end
	end, (ActivityBoostConfig.WORLD_BOSS_FIGHT_SEC or 1200) * 1000)
end

--- Keep arena free until a player joins a specific boss. No auto-spawn.
function ActivityBoostWorldBoss.ensureBand(band)
	if not band or not band.id then
		return false
	end
	local session = ActivityBoostWorldBoss.active[band.id]
	return session ~= nil and not session.tearingDown and not session.bossDead
end

function ActivityBoostWorldBoss.ensureAllBands()
	ActivityBoostWorldBoss.broadcastSchedule()
end

function ActivityBoostWorldBoss.tick()
	-- Lazy spawn: sessions start on join. Tick only refreshes clients when cooldowns expire.
	local now = os.time()
	local changed = false
	for key, untilTs in pairs(ActivityBoostWorldBoss.bossCooldownUntil) do
		if type(untilTs) == "number" and untilTs > 0 and untilTs <= now then
			ActivityBoostWorldBoss.bossCooldownUntil[key] = nil
			changed = true
		end
	end
	if changed then
		ActivityBoostWorldBoss.broadcastSchedule()
	end
end

function ActivityBoostWorldBoss.startSession(sessionIndex)
	-- Timed world-event pulse: clear cooldowns; fights start when players join.
	sessionIndex = tonumber(sessionIndex) or 0
	for _, band in ipairs(ActivityBoostConfig.LEVEL_BANDS or {}) do
		for _, bossName in ipairs(poolForBand(band.id)) do
			ActivityBoostWorldBoss.bossCooldownUntil[cooldownKey(band.id, bossName)] = nil
		end
	end
	Game.broadcastMessage(
		string.format("World Boss window open (slot %d)! Join any available fight from Expeditions.", sessionIndex),
		MESSAGE_EVENT_ADVANCE
	)
	ActivityBoostWorldBoss.broadcastSchedule()
end

function ActivityBoostWorldBoss.join(player, bandId, bossName)
	if not player then
		return false, "Invalid player."
	end
	if isFraggedToday(player) then
		local cap = tonumber(ActivityBoostConfig.WORLD_BOSS_DAILY_CAP) or 3
		return false, string.format("You already claimed %d world bosses today. Come back after server save.", cap)
	end
	if ExpeditionManager and ExpeditionManager.getSessionByPlayer and ExpeditionManager.getSessionByPlayer(player) then
		return false, "Leave your current expedition first."
	end
	local band = nil
	for _, b in ipairs(ActivityBoostConfig.LEVEL_BANDS or {}) do
		if b.id == bandId then
			band = b
			break
		end
	end
	if not band then
		return false, "Unknown level band."
	end
	if not (PzTeleport and PzTeleport.isGod and PzTeleport.isGod(player)) then
		local level = player:getLevel()
		if level < (band.levelMin or 0) or level > (band.levelMax or 99999) then
			return false, string.format("This world boss is for levels %d–%d.", band.levelMin, band.levelMax)
		end
	end
	if bossName and not bossInBandPool(bandId, bossName) then
		return false, "That boss is not offered in this level band."
	end

	local session = ActivityBoostWorldBoss.active[bandId]
	if session and not session.tearingDown and not session.bossDead then
		if bossName and session.bossName ~= bossName then
			return false, string.format("%s is fighting in this arena right now. Pick that fight or wait.", session.bossName)
		end
	else
		local wanted = bossName
		if wanted then
			if bossOnCooldown(bandId, wanted) then
				return false, "That world boss is recovering (30 minute cooldown after defeat)."
			end
		else
			wanted = firstAvailableBoss(bandId)
			if not wanted then
				return false, "All world bosses in this band are on cooldown."
			end
		end
		if session then
			teardownSession(session, "replaced")
		end
		startBandSession(band, wanted)
		session = ActivityBoostWorldBoss.active[bandId]
	end

	if not session or session.tearingDown or session.bossDead then
		return false, "That world boss is not available right now."
	end
	if bossOnCooldown(bandId, session.bossName) then
		return false, "World boss is recovering (30 minute cooldown after defeat)."
	end
	if PzTeleport and PzTeleport.isAllowed then
		local allowed, pzErr = PzTeleport.isAllowed(player)
		if not allowed then
			return false, pzErr or "You can only join from a protection zone."
		end
	end

	ExpeditionManager.saveReturnPos(player)
	ExpeditionManager.markActiveFlag(player, "worldboss:" .. bandId, session.instance.instanceId)

	local key = "worldboss:" .. bandId .. ":p" .. player:getGuid()
	local member = {
		key = key,
		playerId = player:getId(),
		guid = player:getGuid(),
		playerIds = session.playerIds,
		kind = "worldboss",
		bandId = bandId,
		role = "monster",
		catalog = {
			id = "worldboss:" .. bandId,
			name = session.bossName,
			kind = "worldboss",
			role = "monster",
		},
		instance = session.instance,
		state = "hunting",
		startedAt = session.startedAt,
		entered = false,
	}
	session.playerIds[#session.playerIds + 1] = player:getId()
	session.memberKeys[player:getId()] = key
	ExpeditionManager.bindSession(member)

	player:registerEvent("ExpeditionPlayerDeath")
	player:registerEvent("ActivityBoostWorldBossPlayerHealth")
	player:registerEvent("ActivityBoostWorldBossPrepareDeath")
	if player.setDropLoot then
		player:setDropLoot(false)
	end
	if player.setSkillLoss then
		player:setSkillLoss(false)
	end

	local instance = session.instance
	if InstanceWorld and InstanceWorld.enterInstance then
		InstanceWorld.enterInstance(player, instance.instanceId, instance.entry, "worldboss:" .. bandId)
	else
		if player.setInstanceId then
			player:setInstanceId(instance.instanceId)
		end
		player:teleportTo(instance.entry)
	end
	member.entered = true
	player:sendTextMessage(
		MESSAGE_EVENT_ADVANCE,
		string.format("Joined World Boss: %s (%s band). Open PvP - no skulls, no death penalty.", session.bossName, band.name)
	)
	ExpeditionProtocol.sendStatus(player, member)
	ActivityBoostWorldBoss.broadcastSchedule()
	broadcastMeter(session)
	return true
end

function ActivityBoostWorldBoss.withdrawDamage(player)
	local session = nil
	local member = ExpeditionManager and ExpeditionManager.getSessionByPlayer and ExpeditionManager.getSessionByPlayer(player)
	if member and member.kind == "worldboss" then
		session = ActivityBoostWorldBoss.active[member.bandId]
	end
	if not session or not player then
		return
	end
	local guid = player:getGuid()
	local contrib = session.playerDamage[guid]
	if not contrib then
		return
	end
	local entry = session.damage[contrib.key]
	if entry then
		entry.damage = math.max(0, (entry.damage or 0) - (contrib.amount or 0))
		if entry.memberGuids then
			entry.memberGuids[guid] = nil
			local any = false
			for _ in pairs(entry.memberGuids) do
				any = true
				break
			end
			if not any or entry.damage <= 0 then
				session.damage[contrib.key] = nil
			end
		elseif entry.damage <= 0 then
			session.damage[contrib.key] = nil
		end
	end
	session.playerDamage[guid] = nil
	broadcastMeter(session)
end

function ActivityBoostWorldBoss.leave(player, opts)
	opts = opts or {}
	if not player then
		return
	end
	local member = ExpeditionManager and ExpeditionManager.getSessionByPlayer and ExpeditionManager.getSessionByPlayer(player)
	if not member or member.kind ~= "worldboss" then
		return
	end
	local session = ActivityBoostWorldBoss.active[member.bandId]
	if session and not session.bossDead and not opts.force then
		ActivityBoostWorldBoss.withdrawDamage(player)
	end

	if player.setDropLoot then
		player:setDropLoot(true)
	end
	if player.setSkillLoss then
		player:setSkillLoss(true)
	end
	if player.setSkull then
		pcall(function()
			player:setSkull(SKULL_NONE)
		end)
	end

	local pid = player:getId()
	if session and session.playerIds then
		for i = #session.playerIds, 1, -1 do
			if session.playerIds[i] == pid then
				table.remove(session.playerIds, i)
			end
		end
		if session.memberKeys then
			session.memberKeys[pid] = nil
		end
	end

	ExpeditionManager.unbindSession(member)
	ExpeditionManager.clearActiveFlag(player)
	ExpeditionManager.clearAreaEffects(player)
	local returnPos = ExpeditionManager.loadReturnPos(player)
	if player.setInstanceId then
		player:setInstanceId(0)
	end
	if returnPos then
		player:teleportTo(returnPos)
	end
	if ExpeditionProtocol and ExpeditionProtocol.sendEnded then
		ExpeditionProtocol.sendEnded(player)
	end
	if not opts.silent then
		player:sendTextMessage(MESSAGE_EVENT_ADVANCE, opts.reason or "Left world boss.")
	end
	ActivityBoostWorldBoss.broadcastSchedule()
end

--- Arena knockout instead of true death: leave at 1 HP, freeze 10s, then full heal in place.
function ActivityBoostWorldBoss.onPlayerHealthChange(creature, attacker, primaryDamage, primaryType, secondaryDamage, secondaryType, origin)
	local player = creature and creature:getPlayer()
	if not player then
		return primaryDamage, primaryType, secondaryDamage, secondaryType
	end
	local member = ExpeditionManager.getSessionByPlayer(player)
	if not member or member.kind ~= "worldboss" then
		return primaryDamage, primaryType, secondaryDamage, secondaryType
	end
	local session = ActivityBoostWorldBoss.active[member.bandId]
	if not session then
		return primaryDamage, primaryType, secondaryDamage, secondaryType
	end

	-- Suppress skull from PvP hits.
	if attacker and attacker:isPlayer() and player.setSkull then
		addEvent(function()
			local p = Player(player:getId())
			local a = Player(attacker:getId())
			if p and p.setSkull then
				pcall(function()
					p:setSkull(SKULL_NONE)
				end)
			end
			if a and a.setSkull then
				pcall(function()
					a:setSkull(SKULL_NONE)
				end)
			end
		end, 50)
	end

	local untilTs = session.knockoutUntil and session.knockoutUntil[player:getId()]
	if untilTs and os.time() < untilTs then
		-- Immune while knocked out.
		return 0, primaryType, 0, secondaryType
	end

	local health = player:getHealth()
	local dmg = 0
	local pDmg = tonumber(primaryDamage) or 0
	local sDmg = tonumber(secondaryDamage) or 0
	if pDmg < 0 then
		dmg = dmg - pDmg
	end
	if sDmg < 0 then
		dmg = dmg - sDmg
	end
	if dmg <= 0 then
		return primaryDamage, primaryType, secondaryDamage, secondaryType
	end
	if health - dmg > 0 then
		return primaryDamage, primaryType, secondaryDamage, secondaryType
	end

	-- Knockout: clamp to 1 HP and start respawn timer.
	local keep = math.max(0, health - 1)
	session.knockoutUntil = session.knockoutUntil or {}
	local delay = ActivityBoostConfig.WORLD_BOSS_RESPAWN_SEC or 10
	session.knockoutUntil[player:getId()] = os.time() + delay
	player:sendTextMessage(MESSAGE_EVENT_ADVANCE, string.format("Knocked out! Respawning in %ds...", delay))
	local pid = player:getId()
	local pos = player:getPosition()
	addEvent(function()
		local p = Player(pid)
		local s = ActivityBoostWorldBoss.active[member.bandId]
		if not p then
			return
		end
		if s and s.knockoutUntil then
			s.knockoutUntil[pid] = nil
		end
		local m = ExpeditionManager.getSessionByPlayer(p)
		if not m or m.kind ~= "worldboss" then
			return
		end
		p:teleportTo(pos)
		if p.getMaxHealth then
			p:addHealth(p:getMaxHealth())
		end
		if p.getMaxMana then
			p:addMana(p:getMaxMana())
		end
		p:sendTextMessage(MESSAGE_EVENT_ADVANCE, "World Boss respawn - back in the fight!")
	end, delay * 1000)

	-- Apply only enough damage to leave 1 HP (primary negative in Crystal).
	return -keep, primaryType, 0, secondaryType
end

function ActivityBoostWorldBoss.onPlayerPrepareDeath(player)
	if not player then
		return true
	end
	local member = ExpeditionManager and ExpeditionManager.getSessionByPlayer and ExpeditionManager.getSessionByPlayer(player)
	if not member or member.kind ~= "worldboss" then
		return true
	end
	if player.setDropLoot then
		player:setDropLoot(false)
	end
	if player.setSkillLoss then
		player:setSkillLoss(false)
	end
	-- Prefer knockout via health change; if death still happens, no loot/skills.
	return true
end

function ActivityBoostWorldBoss.onPlayerDeath(player, corpse)
	-- Fallback if knockout missed: restore flags and eject with no penalty messaging.
	if not player then
		return true
	end
	local member = ExpeditionManager and ExpeditionManager.getSessionByPlayer and ExpeditionManager.getSessionByPlayer(player)
	if not member or member.kind ~= "worldboss" then
		return true
	end
	if player.setDropLoot then
		player:setDropLoot(false)
	end
	if player.setSkillLoss then
		player:setSkillLoss(false)
	end
	return true
end

function ActivityBoostWorldBoss.onHealthChange(creature, attacker, primaryDamage, primaryType, secondaryDamage, secondaryType, origin)
	if not creature or not creature:isMonster() then
		return primaryDamage, primaryType, secondaryDamage, secondaryType
	end
	local session = nil
	for _, s in pairs(ActivityBoostWorldBoss.active) do
		if s.bossCreatureId == creature:getId() then
			session = s
			break
		end
	end
	if not session or session.bossDead then
		return primaryDamage, primaryType, secondaryDamage, secondaryType
	end
	local player = attacker and attacker:getPlayer()
	if not player then
		local master = attacker and attacker.getMaster and attacker:getMaster()
		player = master and master.getPlayer and master:getPlayer() or nil
	end
	if not player then
		return primaryDamage, primaryType, secondaryDamage, secondaryType
	end
	local pDmg = tonumber(primaryDamage) or 0
	local sDmg = tonumber(secondaryDamage) or 0
	local dmg = 0
	if pDmg < 0 then
		dmg = dmg - pDmg
	end
	if sDmg < 0 then
		dmg = dmg - sDmg
	end
	if dmg <= 0 then
		return primaryDamage, primaryType, secondaryDamage, secondaryType
	end
	local key, name, isParty = partyLeaderKey(player)
	if not key then
		return primaryDamage, primaryType, secondaryDamage, secondaryType
	end
	session.damage[key] = session.damage[key]
		or { name = name, damage = 0, isParty = isParty, memberGuids = {} }
	session.damage[key].damage = (session.damage[key].damage or 0) + dmg
	session.damage[key].name = name
	session.damage[key].memberGuids[player:getGuid()] = true

	local guid = player:getGuid()
	local prev = session.playerDamage[guid]
	if prev and prev.key ~= key then
		local old = session.damage[prev.key]
		if old then
			old.damage = math.max(0, (old.damage or 0) - (prev.amount or 0))
		end
		session.playerDamage[guid] = { key = key, amount = dmg }
	else
		session.playerDamage[guid] = {
			key = key,
			amount = (prev and prev.amount or 0) + dmg,
		}
	end
	broadcastMeter(session)
	return primaryDamage, primaryType, secondaryDamage, secondaryType
end

function ActivityBoostWorldBoss.onBossDeath(creature)
	if not creature then
		return
	end
	local session = nil
	for _, s in pairs(ActivityBoostWorldBoss.active) do
		if s.bossCreatureId == creature:getId() then
			session = s
			break
		end
	end
	if not session or session.bossDead then
		return
	end
	session.bossDead = true
	session.bossCreatureId = nil
	ActivityBoostWorldBoss.bossCooldownUntil[cooldownKey(session.bandId, session.bossName)] = os.time()
		+ (ActivityBoostConfig.WORLD_BOSS_COOLDOWN_SEC or 1800)
	local ranking = meterList(session)

	local guidToPlayer = {}
	for _, pid in ipairs(session.playerIds or {}) do
		local p = Player(pid)
		if p then
			guidToPlayer[p:getGuid()] = p
		end
	end

	for _, row in ipairs(ranking) do
		local recipients = {}
		if row.isParty then
			for guid in pairs(row.memberGuids or {}) do
				local p = guidToPlayer[guid]
				if p then
					recipients[#recipients + 1] = p
				end
			end
		else
			local guid = tonumber(tostring(row.key):match("solo:(%d+)"))
			local p = guid and guidToPlayer[guid]
			if p then
				recipients[#recipients + 1] = p
			end
		end
		for _, p in ipairs(recipients) do
			rollLootForPlayer(p, session.bossName, row.lootMult)
			noteWorldBossFrag(p)
			local frags = 0
			if ActivityBoostActivities and ActivityBoostActivities.getWorldBossFragsToday then
				frags = ActivityBoostActivities.getWorldBossFragsToday(p)
			end
			local cap = tonumber(ActivityBoostConfig.WORLD_BOSS_DAILY_CAP) or 3
			p:sendTextMessage(
				MESSAGE_EVENT_ADVANCE,
				string.format(
					"World Boss fragged! Rank #%d (%s). Progress %d/%d today.",
					row.rank,
					row.name,
					math.min(frags, cap),
					cap
				)
			)
		end
	end

	Game.broadcastMessage(
		string.format("World Boss defeated: %s (%s band)!", session.bossName, session.bandId),
		MESSAGE_EVENT_ADVANCE
	)

	local bandId = session.bandId
	local cooldownSec = ActivityBoostConfig.WORLD_BOSS_COOLDOWN_SEC or 1800
	addEvent(function()
		local s = ActivityBoostWorldBoss.active[bandId]
		if s then
			teardownSession(s, "cleared")
		end
		ActivityBoostWorldBoss.broadcastSchedule()
	end, 8000)
	addEvent(function()
		ActivityBoostWorldBoss.broadcastSchedule()
	end, (cooldownSec + 8) * 1000)
end

function ActivityBoostWorldBoss.onServerSave()
	for _, session in pairs(ActivityBoostWorldBoss.active) do
		teardownSession(session, "serversave")
	end
end
