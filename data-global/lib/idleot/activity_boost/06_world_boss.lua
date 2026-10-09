ActivityBoostWorldBoss = ActivityBoostWorldBoss or {}

-- Live fights keyed by World Boss entry id (one private instance per entry).
ActivityBoostWorldBoss.active = ActivityBoostWorldBoss.active or {}
-- Entry respawn after a kill: entry id -> unix time it can be fought again.
ActivityBoostWorldBoss.respawnUntil = ActivityBoostWorldBoss.respawnUntil or {}

local function lootMultForRank(rank)
	local table_ = ActivityBoostConfig.WORLD_BOSS_LOOT_MULT or {}
	local floor = ActivityBoostConfig.WORLD_BOSS_LOOT_MULT_FLOOR or 0.15
	return table_[rank] or floor
end

local function respawnPending(entryId, now)
	local untilTs = ActivityBoostWorldBoss.respawnUntil[entryId] or 0
	return untilTs > (now or os.time()), untilTs
end

local function respawnSecFor(entry)
	local sec = tonumber(entry and entry.respawnSec)
	if sec and sec > 0 then
		return sec
	end
	return ActivityBoostConfig.WORLD_BOSS_COOLDOWN_SEC or 1800
end

--- Per-player boss cooldown after a kill: the boss's own timer, else the server default (20h).
local function fightAgainSecFor(entry)
	local sec = tonumber(entry and entry.fightAgainSec)
	if sec and sec > 0 then
		return sec
	end
	return ExpeditionConfig.bossCooldownDurationSec()
end

local function bossNamesOf(entry)
	local names = { entry.name }
	for _, add in ipairs(entry.adds or {}) do
		if add.boss then
			names[#names + 1] = add.name
		end
	end
	return names
end

local function isFraggedToday(player)
	return ActivityBoostActivities.worldBossCapReached(player)
end

local function noteWorldBossFrag(player)
	ActivityBoostActivities.addProgress(player, "world_boss", 1)
end

local function partyLeaderKey(player)
	if not player then
		return nil
	end
	local party = player:getParty()
	if party then
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
	local payload = {
		type = "worldBossMeter",
		id = session.entryId,
		bossName = session.label,
		ranking = meterList(session),
	}
	for _, pid in ipairs(session.playerIds or {}) do
		local p = Player(pid)
		if p and ActivityBoostProtocol.send then
			ActivityBoostProtocol.send(p, payload)
		end
	end
end

local function rollLootForPlayer(player, bossName, mult)
	local mType = MonsterType(bossName)
	if not mType then
		return {}
	end
	local loot = mType:getLoot()
	if type(loot) ~= "table" then
		return {}
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
	return given
end

local function sessionMonsterIds(session)
	local ids = {}
	for id in pairs(session.baseMaxHealth or {}) do
		ids[#ids + 1] = id
	end
	return ids
end

--- Boss + adds max HP follow the joined player count (keeps the current HP fraction).
local function rescaleHealth(session)
	if not session or session.bossDead or session.tearingDown then
		return
	end
	local mult = ActivityBoostConfig.worldBossPlayerHpMult(#(session.playerIds or {}))
	if session.hpMult == mult then
		return
	end
	session.hpMult = mult
	for id, baseMax in pairs(session.baseMaxHealth or {}) do
		local monster = Monster(id)
		if monster then
			local oldMax = math.max(1, monster:getMaxHealth())
			local newMax = math.max(1, math.ceil(baseMax * mult))
			local hp = monster:getHealth()
			monster:setMaxHealth(newMax)
			monster:setHealth(math.max(1, math.floor(hp * newMax / oldMax)))
		end
	end
end

local function teardownSession(session, reason)
	if not session or session.tearingDown then
		return
	end
	session.tearingDown = true
	session.scope:dispose()
	for _, id in ipairs(sessionMonsterIds(session)) do
		local monster = Monster(id)
		if monster then
			monster:setDropLoot(false)
			monster:remove()
		end
	end
	session.baseMaxHealth = {}
	local playerIds = session.playerIds or {}
	for i = #playerIds, 1, -1 do
		local p = Player(playerIds[i])
		if p then
			ActivityBoostWorldBoss.leave(p, { silent = true, force = true, reason = reason })
		end
	end
	if session.instance then
		ExpeditionInstance.teardown(session.instance)
	end
	if ActivityBoostWorldBoss.active[session.entryId] == session then
		ActivityBoostWorldBoss.active[session.entryId] = nil
	end
	ActivityBoostWorldBoss.broadcastSchedule()
end

--- True while `session` is still the entry's live fight (timers captured it earlier).
local function isCurrentSession(session)
	return session ~= nil
		and ActivityBoostWorldBoss.active[session.entryId] == session
		and not session.tearingDown
		and Instance.isLive(session.key, session.owner)
end

local function liveSession(entryId)
	local session = ActivityBoostWorldBoss.active[entryId]
	if session and not session.tearingDown and not session.bossDead then
		return session
	end
	return nil
end

--- Session that owns monster `creatureId` (boss, twin boss or add).
function ActivityBoostWorldBoss.sessionForMonster(creatureId)
	for _, session in pairs(ActivityBoostWorldBoss.active) do
		if session.baseMaxHealth and session.baseMaxHealth[creatureId] then
			return session
		end
	end
	return nil
end

function ActivityBoostWorldBoss.isBossMonster(session, creatureId)
	return session ~= nil and session.bossIds ~= nil and session.bossIds[creatureId] == true
end

local function scheduleRow(entry, now)
	local session = ActivityBoostWorldBoss.active[entry.id]
	local live = session and not session.tearingDown and not session.bossDead
	local onRespawn, respawnAt = respawnPending(entry.id, now)
	local available, availableAt = ExpeditionConfig.bossAvailability(entry, now)
	local state, nextAt = "NOW", now
	if not available then
		state, nextAt = "LOCKED", availableAt
	elseif onRespawn then
		state, nextAt = "COOLDOWN", respawnAt
	elseif live then
		state = "ACTIVE"
	end
	return {
		id = entry.id,
		bossName = entry.name,
		label = ActivityBoostConfig.worldBossLabel(entry),
		displayName = entry.displayName,
		creatureId = tonumber(entry.creatureId),
		levelMin = entry.levelMin,
		family = entry.family or "Misc",
		difficulty = entry.difficulty or 0,
		variantOf = entry.variantOf,
		arena = entry.room == nil,
		nextAt = nextAt,
		nextClock = state,
		cooldownUntil = onRespawn and respawnAt or 0,
		active = live and true or false,
		joinable = available and not onRespawn,
		players = live and #(session.playerIds or {}) or 0,
		available = available,
		availableAt = availableAt,
		availabilityLabel = ExpeditionConfig.availabilityLabel(entry, now),
		endsAt = live and session.endsAt or 0,
	}
end

function ActivityBoostWorldBoss.listActive()
	local now = os.time()
	local out = {}
	for entryId, session in pairs(ActivityBoostWorldBoss.active) do
		local entry = ActivityBoostConfig.worldBoss(entryId)
		if entry and session and not session.tearingDown then
			local row = scheduleRow(entry, now)
			row.startedAt = session.startedAt
			row.joinUntil = session.joinUntil
			out[#out + 1] = row
		end
	end
	table.sort(out, function(a, b)
		return (a.levelMin or 0) < (b.levelMin or 0)
	end)
	return out
end

--- One row per World Boss entry (base boss or gap variant).
function ActivityBoostWorldBoss.listSchedule()
	local now = os.time()
	local out = {}
	for _, entry in ipairs(ActivityBoostConfig.WORLD_BOSSES or {}) do
		out[#out + 1] = scheduleRow(entry, now)
	end
	return out
end

function ActivityBoostWorldBoss.broadcastSchedule()
	local payload = {
		type = "worldBossSchedule",
		active = ActivityBoostWorldBoss.listActive(),
		schedule = ActivityBoostWorldBoss.listSchedule(),
		sessionTimes = ActivityBoostConfig.WORLD_BOSS_SESSION_TIMES or {},
	}
	for _, player in ipairs(Game.getPlayers()) do
		ActivityBoostProtocol.send(player, payload)
	end
end

--- Instance spec: the boss's own spawn room, else the generic arena.
local function roomSpec(entry)
	local room = entry.room
	if type(room) == "table" and room.center then
		local z = room.center.z
		return {
			center = room.center,
			entry = room.entry,
			boundary = room.boundary,
			occupancy = room.occupancyMask,
			floors = { z },
			bossPos = room.center,
		}
	end
	local arena = ActivityBoostConfig.WORLD_BOSS_ARENA
	return {
		center = arena.center,
		boundary = arena.boundary,
		bossPos = arena.center,
	}
end

local function spawnNear(name, pos, instance)
	local instanceId = instance.instanceId
	local monster = Game.createMonster(name, pos, false, false, nil, instanceId)
	if monster then
		return monster
	end
	local reserved = {}
	ExpeditionInstance.reservePos(reserved, pos)
	for radius = 1, 3 do
		local near = ExpeditionInstance.randomAttackRangeWalkable(instance, pos, radius, reserved)
		if near then
			monster = Game.createMonster(name, near, false, false, nil, instanceId)
			if monster then
				return monster
			end
			ExpeditionInstance.reservePos(reserved, near)
		end
	end
	return Game.createMonster(name, pos, false, true, nil, instanceId)
end

local onBossDeath

local function trackMonster(session, monster, isBoss, difficultyMults)
	monster:setDropLoot(false)
	monster:registerEvent("IdleMonsterDeath")
	if isBoss then
		monster:registerEvent("ActivityBoostWorldBossHealth")
		if difficultyMults then
			monster:scaleCombat(difficultyMults[1], difficultyMults[2])
		end
		session.bossIds[monster:getId()] = true
		session.bossesAlive = session.bossesAlive + 1
	end
	session.baseMaxHealth[monster:getId()] = monster:getMaxHealth()
end

local function startEntrySession(entry)
	local existing = ActivityBoostWorldBoss.active[entry.id]
	if existing then
		teardownSession(existing, "replaced")
	end
	local spec = roomSpec(entry)
	local subarea = InstanceWorld.subareaIdAt(Position(spec.center.x, spec.center.y, spec.center.z)) or 0
	-- Owner is unique per fight so stale timers can never match a later fight of the same entry.
	local owner = string.format("worldboss_%s_%d", entry.id, os.time())
	local instanceId = ExpeditionInstance.allocate("worldboss", subarea, owner, entry.id)
	if not instanceId then
		logger.error("[ActivityBoost] world boss: no instance for {}", entry.id)
		return nil
	end
	local instance, err = ExpeditionInstance.build(instanceId, {
		id = "worldboss_" .. entry.id,
		region = "worldboss_" .. entry.id,
		kind = "worldboss",
		center = spec.center,
		entry = spec.entry,
		boundary = spec.boundary,
		occupancy = spec.occupancy,
		floors = spec.floors,
	}, os.time())
	if not instance then
		ExpeditionInstance.free(instanceId)
		logger.error("[ActivityBoost] world boss build failed {}: {}", entry.id, err or "?")
		return nil
	end

	local now = os.time()
	local fightSec = ActivityBoostConfig.WORLD_BOSS_FIGHT_SEC or 1200
	local session = {
		entryId = entry.id,
		entry = entry,
		bossName = entry.name,
		label = ActivityBoostConfig.worldBossLabel(entry),
		key = instanceId,
		owner = owner,
		instance = instance,
		playerIds = {},
		memberKeys = {},
		damage = {},
		playerDamage = {},
		bossIds = {},
		bossesAlive = 0,
		baseMaxHealth = {},
		hpMult = 1,
		startedAt = now,
		joinUntil = now + fightSec,
		endsAt = now + fightSec,
		bossDead = false,
		tearingDown = false,
	}
	session.scope = Scope.new({
		name = "worldboss:" .. entry.id,
		instanceId = instanceId,
		alive = function()
			return isCurrentSession(session)
		end,
	})
	ActivityBoostWorldBoss.active[entry.id] = session

	local hpMult, dmgMult = ActivityBoostConfig.worldBossDifficultyMults(entry)
	local difficulty = (hpMult > 1 or dmgMult > 1) and { hpMult, dmgMult } or nil
	local bossPos = Position(spec.bossPos.x, spec.bossPos.y, spec.bossPos.z)
	local boss = Game.createMonster(entry.name, bossPos, false, true, nil, instanceId)
	if boss then
		trackMonster(session, boss, true, difficulty)
	else
		logger.error("[ActivityBoost] failed to spawn world boss {}", entry.name)
	end
	for _, add in ipairs(entry.adds or {}) do
		local monster = spawnNear(add.name, Position(add.x, add.y, add.z), instance)
		if monster then
			trackMonster(session, monster, add.boss == true, add.boss and difficulty or nil)
		end
	end
	if session.bossesAlive == 0 then
		teardownSession(session, "spawnfailed")
		return nil
	end

	session.scope:on("monster.died", function(dead)
		if session.bossIds[dead:getId()] then
			session.bossIds[dead:getId()] = nil
			session.baseMaxHealth[dead:getId()] = nil
			session.bossesAlive = session.bossesAlive - 1
			if session.bossesAlive <= 0 then
				onBossDeath(session)
			end
		else
			session.baseMaxHealth[dead:getId()] = nil
		end
	end)

	session.scope:after(fightSec * 1000, function()
		if session.bossDead then
			return
		end
		Game.broadcastMessage(
			string.format("World Boss: time expired - %s escaped.", session.label),
			MESSAGE_EVENT_ADVANCE
		)
		teardownSession(session, "timeout")
	end)
	return session
end

function ActivityBoostWorldBoss.ensureAll()
	ActivityBoostWorldBoss.broadcastSchedule()
end

function ActivityBoostWorldBoss.startSession(sessionIndex)
	-- Timed world-event pulse: entry respawns reset; per-player boss cooldowns stay.
	sessionIndex = tonumber(sessionIndex) or 0
	ActivityBoostWorldBoss.respawnUntil = {}
	Game.broadcastMessage(
		string.format("World Boss window open (slot %d)! Join any available fight from Expeditions.", sessionIndex),
		MESSAGE_EVENT_ADVANCE
	)
	ActivityBoostWorldBoss.broadcastSchedule()
end

--- Join gate: daily cap, event window, level >= levelMin (no top cap), personal boss
--- cooldown, entry respawn. Returns ok, errorMessage.
local function canJoin(player, entry)
	if isFraggedToday(player) then
		local cap = tonumber(ActivityBoostConfig.WORLD_BOSS_DAILY_CAP) or 3
		return false, string.format("You already claimed %d world bosses today. Come back after server save.", cap)
	end
	if ExpeditionManager.getSessionByPlayer(player) then
		return false, "Leave your current expedition first."
	end
	local label = ActivityBoostConfig.worldBossLabel(entry)
	local available = ExpeditionConfig.bossAvailability(entry)
	if not available then
		local when = ExpeditionConfig.availabilityLabel(entry)
		return false, string.format("%s is not available right now (%s).", label, when or "event only")
	end
	if PzTeleport.isGod(player) then
		return true
	end
	if player:getLevel() < entry.levelMin then
		return false, string.format("%s requires level %d.", label, entry.levelMin)
	end
	if not player:canFightBoss(entry.name) then
		local left = math.max(0, (tonumber(player:getBossCooldown(entry.name)) or 0) - os.time())
		return false, string.format(
			"You must wait %s to face %s again.",
			ExpeditionConfig.formatBossCooldownRemaining(left),
			entry.name
		)
	end
	if respawnPending(entry.id) then
		return false, string.format("%s has not respawned yet.", label)
	end
	if PzTeleport.isCombatLocked(player) then
		return false, PzTeleport.PZ_LOCKED_MESSAGE or "You cannot teleport while PZ-locked."
	end
	return true
end

function ActivityBoostWorldBoss.join(player, entryId)
	if not player then
		return false, "Invalid player."
	end
	local entry = ActivityBoostConfig.worldBoss(entryId)
	if not entry then
		return false, "Unknown world boss."
	end
	local ok, err = canJoin(player, entry)
	if not ok then
		return false, err
	end

	local session = liveSession(entry.id) or startEntrySession(entry)
	if not session then
		return false, "That world boss is not available right now."
	end

	ExpeditionManager.saveReturnPos(player)
	ExpeditionManager.markActiveFlag(player, "worldboss:" .. entry.id)

	local key = "worldboss:" .. entry.id .. ":p" .. player:getGuid()
	local member = {
		key = key,
		playerId = player:getId(),
		guid = player:getGuid(),
		playerIds = session.playerIds,
		kind = "worldboss",
		entryId = entry.id,
		-- role=boss so status + mid-screen boss crest track the world boss.
		role = "boss",
		catalog = {
			id = "worldboss:" .. entry.id,
			name = entry.name,
			kind = "worldboss",
			role = "boss",
		},
		instance = session.instance,
		state = "hunting",
		startedAt = session.startedAt,
		entered = false,
	}
	session.playerIds[#session.playerIds + 1] = player:getId()
	session.memberKeys[player:getId()] = key
	ExpeditionManager.bindSession(member)
	rescaleHealth(session)

	player:registerEvent("ExpeditionPlayerDeath")

	local function finishWorldBossEnter(p)
		local liveMember = ExpeditionManager.getSessionByPlayer(p)
		if not liveMember or liveMember.key ~= key then
			return false
		end
		local current = liveSession(entry.id)
		if not current then
			ActivityBoostWorldBoss.leave(p, { silent = true, force = true })
			return false, "That world boss is not available right now."
		end
		local instance = current.instance
		if not InstanceWorld.enterInstance(p, instance.instanceId, instance.entry) then
			logger.error("[ActivityBoost] enterInstance failed for {} into world boss {}", p:getName(), current.label)
			ActivityBoostWorldBoss.leave(p, { silent = true, force = true })
			return false
		end
		liveMember.entered = true
		p:sendTextMessage(
			MESSAGE_EVENT_ADVANCE,
			string.format("Joined World Boss: %s. Open PvP; no death penalty.", current.label)
		)
		ExpeditionProtocol.sendStatus(p, liveMember)
		ActivityBoostWorldBoss.broadcastSchedule()
		broadcastMeter(current)
		return true
	end

	local armed, armErr = InstanceTeleport.armSoloExpedition(player, {
		onComplete = function(p)
			finishWorldBossEnter(p)
		end,
		onCancel = function(p)
			if p then
				ActivityBoostWorldBoss.leave(p, { silent = true, force = true })
			end
		end,
	})
	if not armed then
		ActivityBoostWorldBoss.leave(player, { silent = true, force = true })
		return false, armErr or "Could not start world boss teleport."
	end
	ExpeditionProtocol.sendStatus(player, member)
	return true
end

function ActivityBoostWorldBoss.withdrawDamage(player)
	local session = nil
	local member = ExpeditionManager.getSessionByPlayer(player)
	if member and member.kind == "worldboss" then
		session = ActivityBoostWorldBoss.active[member.entryId]
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

InstanceKinds.setHooks("worldboss", {
	onRevive = function(p)
		if p then
			p:sendTextMessage(MESSAGE_EVENT_ADVANCE, "World Boss respawn - back in the fight!")
		end
	end,
})

local function endWorldBossKnockout(player)
	-- Mid-knockout leave / eject: softSpawn at temple (not arena), no revive toast.
	SoftDeath.endDowned(player, { reason = "worldboss", revive = false, runCallback = false })
end

function ActivityBoostWorldBoss.leave(player, opts)
	opts = opts or {}
	if not player then
		return
	end
	local member = ExpeditionManager.getSessionByPlayer(player)
	if not member or member.kind ~= "worldboss" then
		return
	end
	local session = ActivityBoostWorldBoss.active[member.entryId]
	if session and not session.bossDead and not opts.force then
		ActivityBoostWorldBoss.withdrawDamage(player)
	end

	endWorldBossKnockout(player)

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
		rescaleHealth(session)
	end

	ExpeditionManager.unbindSession(member)
	ExpeditionManager.clearActiveFlag(player)
	ExpeditionManager.clearAreaEffects(player)
	local returnPos = ExpeditionManager.loadReturnPos(player)
	-- Atomic exit — never setInstanceId(0) then teleport (client ghosts).
	InstanceWorld.exitToOpenWorld(player, returnPos)
	ExpeditionProtocol.sendEnded(player)
	if not opts.silent then
		player:sendTextMessage(MESSAGE_EVENT_ADVANCE, opts.reason or "Left world boss.")
	end
	ActivityBoostWorldBoss.broadcastSchedule()
end

function ActivityBoostWorldBoss.onHealthChange(creature, attacker, primaryDamage, primaryType, secondaryDamage, secondaryType, origin)
	if not creature or not creature:isMonster() then
		return primaryDamage, primaryType, secondaryDamage, secondaryType
	end
	local session = ActivityBoostWorldBoss.sessionForMonster(creature:getId())
	if not session or session.bossDead or not ActivityBoostWorldBoss.isBossMonster(session, creature:getId()) then
		return primaryDamage, primaryType, secondaryDamage, secondaryType
	end
	local player = attacker and attacker:getPlayer()
	if not player then
		local master = attacker and attacker:getMaster()
		player = master and master:getPlayer()
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
	session.damage[key] = session.damage[key] or { name = name, damage = 0, isParty = isParty, memberGuids = {} }
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

onBossDeath = function(session)
	if session.bossDead then
		return
	end
	session.bossDead = true
	local entry = session.entry
	local now = os.time()
	ActivityBoostWorldBoss.respawnUntil[entry.id] = now + respawnSecFor(entry)
	local cooldownUntil = now + fightAgainSecFor(entry)
	local ranking = meterList(session)

	local guidToPlayer = {}
	for _, pid in ipairs(session.playerIds or {}) do
		local p = Player(pid)
		if p then
			guidToPlayer[p:getGuid()] = p
		end
	end

	local cap = tonumber(ActivityBoostConfig.WORLD_BOSS_DAILY_CAP) or 3
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
			local given = {}
			for _, bossName in ipairs(bossNamesOf(entry)) do
				for _, line in ipairs(rollLootForPlayer(p, bossName, row.lootMult)) do
					given[#given + 1] = line
				end
			end
			if #given > 0 then
				p:sendTextMessage(MESSAGE_LOOT, "World boss loot: " .. table.concat(given, ", "))
			else
				p:sendTextMessage(MESSAGE_EVENT_ADVANCE, "World boss loot: nothing this time.")
			end
			if not PzTeleport.isGod(p) then
				p:setBossCooldown(entry.name, cooldownUntil)
				p:sendBosstiaryCooldownTimer()
			end
			noteWorldBossFrag(p)
			local frags = ActivityBoostActivities.getWorldBossFragsToday(p)
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

	Game.broadcastMessage(string.format("World Boss defeated: %s!", session.label), MESSAGE_EVENT_ADVANCE)

	-- Loot window, then the room closes; clients refresh again once the entry respawns.
	session.scope:after(8000, function()
		teardownSession(session, "cleared")
	end)
	addEvent(ActivityBoostWorldBoss.broadcastSchedule, (respawnSecFor(entry) + 1) * 1000)
end

function ActivityBoostWorldBoss.onServerSave()
	for _, session in pairs(ActivityBoostWorldBoss.active) do
		teardownSession(session, "serversave")
	end
end
