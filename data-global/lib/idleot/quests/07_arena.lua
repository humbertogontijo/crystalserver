-- Reusable sequential-pit arena runner on a private instance over live tiles.
-- Catalog rows supply pits/creatures/storages/rewards; Svargrond is one consumer.

QuestArena = QuestArena or {}

QuestArena.ID_BASE = 920000

-- monsterId -> session.key
local monsterOwners = {}
local registered = false

local function isPrivateInstance(thing)
	return thing ~= nil and Instance.isPrivate(Instance.of(thing))
end

local function barb()
	return Storage and Storage.Quest and Storage.Quest.U8_0 and Storage.Quest.U8_0.BarbarianArena or nil
end

local function copyPos(p)
	if not p then
		return nil
	end
	return { x = p.x, y = p.y, z = p.z }
end

local function pitBoundary(pit)
	if not pit or not pit.fromPos or not pit.toPos then
		return nil
	end
	local fromPos, toPos = pit.fromPos, pit.toPos
	return {
		x = fromPos.x,
		y = fromPos.y,
		w = (toPos.x - fromPos.x) + 1,
		h = (toPos.y - fromPos.y) + 1,
		z = fromPos.z,
	}
end

--- Union AABB over all pits so presence checks stay valid while teleporting between pits.
local function unionPitBoundary(pits)
	if type(pits) ~= "table" then
		return nil
	end
	local minX, minY, maxX, maxY, z
	for i = 1, #pits do
		local pit = pits[i]
		if pit and pit.fromPos and pit.toPos then
			local fromPos, toPos = pit.fromPos, pit.toPos
			minX = minX and math.min(minX, fromPos.x) or fromPos.x
			minY = minY and math.min(minY, fromPos.y) or fromPos.y
			maxX = maxX and math.max(maxX, toPos.x) or toPos.x
			maxY = maxY and math.max(maxY, toPos.y) or toPos.y
			z = z or fromPos.z
		end
	end
	if not minX then
		return nil
	end
	return {
		x = minX,
		y = minY,
		w = (maxX - minX) + 1,
		h = (maxY - minY) + 1,
		z = z,
	}
end

local function applyInstanceBoundary(instance, boundary)
	if not instance or not boundary then
		return
	end
	instance.origin = Position(boundary.x, boundary.y, boundary.z)
	instance.width = boundary.w
	instance.height = boundary.h
	instance.mapWidth = boundary.w
	instance.mapHeight = boundary.h
	instance.boundary = boundary
end

local function bindPitGeometry(session, pitIndex)
	if not session or not session.instance or not session.arenaSpec then
		return nil
	end
	local pits = session.arenaSpec.pits
	local pit = pits and pits[pitIndex]
	if not pit then
		return nil
	end
	local instance = session.instance
	instance.entry = Position(pit.center.x, pit.center.y, pit.center.z)
	instance.occupancy = nil
	local floors, floorSet = ExpeditionInstance.floorsFromSpec({ floors = { pit.center.z } }, pit.center.z)
	instance.floors = floors
	instance.floorSet = floorSet
	if InstanceWorld and InstanceWorld.rememberFloors and instance.instanceId then
		InstanceWorld.rememberFloors(instance.instanceId, floorSet)
	end
	session.pitIndex = pitIndex
	session.holdPos = Position(pit.center.x, pit.center.y, pit.center.z)
	session.wave = pitIndex
	return pit
end

local function clearEvents(session)
	if not session then
		return
	end
	if session.arenaKickEvent then
		stopEvent(session.arenaKickEvent)
		session.arenaKickEvent = nil
	end
	if session.arenaSpawnEvent then
		stopEvent(session.arenaSpawnEvent)
		session.arenaSpawnEvent = nil
	end
	if session.arenaFlashEvent then
		stopEvent(session.arenaFlashEvent)
		session.arenaFlashEvent = nil
	end
end

local function removeOwnedMonsters(session)
	if not session then
		return
	end
	for mid, key in pairs(monsterOwners) do
		if key == session.key then
			monsterOwners[mid] = nil
			local monster = Monster(mid)
			if monster then
				if monster.setDropLoot then
					monster:setDropLoot(false)
				end
				monster:remove()
			end
		end
	end
	session.alive = 0
end

local function scheduleKick(session)
	if not session then
		return
	end
	if session.arenaKickEvent then
		stopEvent(session.arenaKickEvent)
		session.arenaKickEvent = nil
	end
	local kickSec = tonumber(session.arenaSpec and session.arenaSpec.kickTimeSec) or 600
	local key = session.key
	session.arenaKickEvent = addEvent(function()
		local s = ExpeditionManager and ExpeditionManager.getSessionByKey and ExpeditionManager.getSessionByKey(key)
		if not s or s.state == "ended" or s.state == "cleared" then
			return
		end
		local player = s.playerId and Player(s.playerId) or nil
		if player then
			player:sendTextMessage(MESSAGE_EVENT_ADVANCE, "Your time ran out!")
		end
		QuestArena.abandon(s, "timeout")
		ExpeditionManager.leaveAll(s, { silent = true })
	end, kickSec * 1000)
end

local function teleportToPit(session, pit)
	if not session or not pit or not ExpeditionInstance.isLive(session.instance) then
		return false
	end
	local instanceId = session.instance.instanceId
	local dest = Position(pit.center.x, pit.center.y, pit.center.z)
	local ok = false
	for _, p in ipairs(ExpeditionManager.onlinePlayers(session)) do
		p:setFollowCreature(nil)
		ok = InstanceWorld.enterInstance(p, instanceId, dest) and true or false
		if ok then
			dest:sendMagicEffect(CONST_ME_MAGIC_RED)
		end
	end
	return ok
end

local function spawnPitMonster(session)
	if not session or session.state == "ended" or session.state == "cleared" then
		return
	end
	local spec = session.arenaSpec
	local pitIndex = session.pitIndex or 1
	local pit = spec and spec.pits and spec.pits[pitIndex]
	local name = spec and spec.creatures and spec.creatures[pitIndex]
	if not pit or not name or name == "" then
		logger.warn("[QuestArena] missing pit/creature at index {}", pitIndex)
		return
	end
	removeOwnedMonsters(session)
	local summon = pit.summon or pit.center
	local pos = Position(summon.x, summon.y, summon.z)
	Game.runInInstance(session.instance.instanceId, function()
		pos:sendMagicEffect(CONST_ME_TELEPORT)
	end)
	local monster = ExpeditionInstance.createMonsterExclusive
			and ExpeditionInstance.createMonsterExclusive(name, pos, session.instance)
		or (ExpeditionInstance.isLive(session.instance) and Game.createMonster(name, pos, false, true, nil, session.instance.instanceId))
	if not monster then
		logger.warn("[QuestArena] failed to spawn '{}' at pit {}", name, pitIndex)
		session.state = "waiting"
		local key = session.key
		session.arenaSpawnEvent = addEvent(function()
			local s = ExpeditionManager.getSessionByKey(key)
			if s and s.state ~= "ended" then
				spawnPitMonster(s)
			end
		end, 1500)
		return
	end
	if monster.runHealth then
		monster:runHealth(0)
	end
	-- Do NOT setDropLoot(false): Crystal skips onDeath for lootDrop=false monsters
	-- that are not summons (creature.cpp dropCorpse), which would stall pit advances.
	-- Arena monster loot tables are already empty.
	if monster.unregisterEvent then
		monster:unregisterEvent("SvargrondArenaBossDeath")
	end
	monster:registerEvent("IdleMonsterDeath")
	monsterOwners[monster:getId()] = session.key
	session.alive = 1
	session.state = "hunting"
	session.reconciling = nil
	session.arenaSpawnEvent = nil
	scheduleKick(session)
	ExpeditionManager.broadcastStatus(session)
	local player = session.playerId and Player(session.playerId) or nil
	if player then
		player:say("Fight!", TALKTYPE_MONSTER_SAY)
		player:sendTextMessage(
			MESSAGE_EVENT_ADVANCE,
			string.format("Arena pit %d/%d: %s", pitIndex, #(spec.creatures or {}), name)
		)
	end
end

local function prepareAndSpawn(session, pitIndex)
	if not session then
		return
	end
	local pit = session.arenaSpec.pits and session.arenaSpec.pits[pitIndex]
	if not pit then
		return
	end
	session.reconciling = true
	local pitBound = bindPitGeometry(session, pitIndex)
	if not pitBound then
		session.reconciling = nil
		return
	end
	local stor = session.arenaSpec and session.arenaSpec.storages
	local player = session.playerId and Player(session.playerId) or nil
	if player and stor and stor.pitDoor then
		player:setStorageValue(stor.pitDoor, pitIndex)
	end
	teleportToPit(session, pitBound)
	session.reconciling = nil
	session.state = "waiting"
	clearEvents(session)
	-- Keep kick armed across pits from first enter; re-arm on each spawn.
	local key = session.key
	local flashes = 2
	local interval = 700
	local function flash(remaining)
		local s = ExpeditionManager.getSessionByKey(key)
		if not s or s.state == "ended" then
			return
		end
		local summon = pit.summon or pit.center
		local pos = Position(summon.x, summon.y, summon.z)
		Game.runInInstance(s.instance.instanceId, function()
			pos:sendMagicEffect(CONST_ME_TELEPORT)
		end)
		if remaining <= 1 then
			s.arenaFlashEvent = nil
			spawnPitMonster(s)
			return
		end
		s.arenaFlashEvent = addEvent(function()
			flash(remaining - 1)
		end, interval)
	end
	session.arenaFlashEvent = addEvent(function()
		flash(flashes)
	end, 400)
	ExpeditionManager.broadcastStatus(session)
end

--- Mark challenge complete (same storages as stock pit>10 reward-room teleport).
function QuestArena.markComplete(player, spec)
	if not player or not spec then
		return
	end
	local stor = spec.storages or {}
	if stor.pitDoor then
		player:setStorageValue(stor.pitDoor, 0)
	end
	if stor.doorAccess then
		player:setStorageValue(stor.doorAccess, 1)
	end
	if stor.questLog then
		player:setStorageValue(stor.questLog, 2)
	end
	if stor.arena and stor.arenaId then
		local cur = math.max(0, player:getStorageValue(stor.arena))
		if cur <= stor.arenaId then
			player:setStorageValue(stor.arena, stor.arenaId + 1)
		end
	end
	if type(spec.achievement) == "string" and spec.achievement ~= "" and player.addAchievement then
		player:addAchievement(spec.achievement)
	end
	player:sendTextMessage(
		MESSAGE_EVENT_ADVANCE,
		string.format(
			"Congratulations! You completed the %s arena. Claim your reward from Quests.",
			spec.name or "arena"
		)
	)
end

function QuestArena.abandon(session, _reason)
	if not session then
		return
	end
	clearEvents(session)
	removeOwnedMonsters(session)
	local player = session.playerId and Player(session.playerId) or nil
	local stor = session.arenaSpec and session.arenaSpec.storages
	if player and stor and stor.pitDoor then
		-- Must re-accept / pay fee (stock coward exit sets PitDoor = -1 / 0).
		player:setStorageValue(stor.pitDoor, 0)
	end
	session.state = "ended"
end

function QuestArena.begin(session)
	if not session or not session.catalog then
		return
	end
	local spec = session.catalog.arenaSpec or QuestArena.specForExpeditionId(session.catalog.id)
	if not spec then
		logger.error("[QuestArena] no arenaSpec for catalog {}", tostring(session.catalog and session.catalog.id))
		return
	end
	session.kind = "arena"
	session.role = "arena"
	session.arenaSpec = spec
	session.pitIndex = 0
	session.alive = 0
	session.kills = 0
	local union = unionPitBoundary(spec.pits)
	if union and session.instance then
		applyInstanceBoundary(session.instance, union)
	end
	-- Cancel the boss spawn timer if join armed one.
	ExpeditionManager.scope(session):cancel("bossSpawn")
	IdleSafe.call("ExpeditionPack.clear", ExpeditionPack.clear, session)
	prepareAndSpawn(session, 1)
end

--- Death entry: resolve session from QuestArena.monsterOwners (reliable at onDeath time).
function QuestArena.handleMonsterDeath(creature)
	local mid = creature:getId()
	local key = monsterOwners[mid]
	if not key then
		return
	end
	local session = ExpeditionManager.getSessionByKey(key)
	if not session then
		monsterOwners[mid] = nil
		return
	end
	QuestArena.onMonsterDeath(session, creature)
end

function QuestArena.onMonsterDeath(session, creature)
	if not session or (session.kind ~= "arena" and session.role ~= "arena") then
		return false
	end
	if not creature then
		return true
	end
	local mid = creature:getId()
	local ownerKey = monsterOwners[mid]
	if not ownerKey or ownerKey ~= session.key then
		return false
	end
	monsterOwners[mid] = nil
	session.alive = 0
	session.kills = (session.kills or 0) + 1

	local spec = session.arenaSpec
	local pitIndex = session.pitIndex or 1
	local total = spec and spec.creatures and #spec.creatures or 10
	local player = session.playerId and Player(session.playerId) or nil
	local stor = spec and spec.storages

	if player and stor and stor.pitDoor then
		player:setStorageValue(stor.pitDoor, pitIndex + 1)
	end
	if player then
		player:say("Victory!", TALKTYPE_MONSTER_SAY)
	end

	if pitIndex >= total then
		session.state = "cleared"
		clearEvents(session)
		if player then
			QuestArena.markComplete(player, spec)
		end
		ExpeditionManager.broadcastStatus(session)
		local key = session.key
		addEvent(function()
			local s = ExpeditionManager.getSessionByKey(key)
			if s then
				ExpeditionManager.leaveAll(s, { silent = false, victory = true })
			end
		end, 1200)
		return true
	end

	local key = session.key
	local nextPit = pitIndex + 1
	session.state = "relocating"
	ExpeditionManager.broadcastStatus(session)
	logger.info("[QuestArena] pit {} cleared, advancing to pit {}/{}", pitIndex, nextPit, total)
	session.arenaSpawnEvent = addEvent(function()
		local s = ExpeditionManager.getSessionByKey(key)
		if s and s.state ~= "ended" and s.state ~= "cleared" then
			prepareAndSpawn(s, nextPit)
		end
	end, 900)
	return true
end

IdleEvents.on("monster.died", QuestArena.handleMonsterDeath, "QuestArena")

function QuestArena.clear(session)
	clearEvents(session)
	removeOwnedMonsters(session)
end

function QuestArena.onSessionCleanup(session, opts)
	if not session or session.kind ~= "arena" then
		return
	end
	local victory = opts and opts.victory == true
	if not victory and session.state ~= "cleared" then
		QuestArena.abandon(session, "leave")
	else
		clearEvents(session)
		removeOwnedMonsters(session)
	end
end

-- --- Svargrond registration -------------------------------------------------

local function buildPitsFromStock()
	local out = {}
	if type(PITS) ~= "table" then
		return out
	end
	for i = 1, 10 do
		local pit = PITS[i]
		if pit then
			out[i] = {
				fromPos = copyPos(pit.fromPos),
				toPos = copyPos(pit.toPos),
				center = copyPos(pit.center),
				summon = copyPos(pit.summon),
				pillar = copyPos(pit.pillar),
				tp = copyPos(pit.tp),
			}
		end
	end
	return out
end

local REWARD_UIDS = {
	[1] = { 6220, 6221, 6222, 6223, 6224 },
	[2] = { 6225, 6226, 6227, 6228, 6229 },
	[3] = { 6230, 6231, 6232, 6233, 6234 },
}

local TROPHY = {
	[1] = { uid = 3264, itemId = 5807, storageKey = "TrophyGreenhorn", desc = "It is given to the courageous victor of the barbarian arena in greenhorn difficulty. Awarded to %s" },
	[2] = { uid = 3265, itemId = 5806, storageKey = "TrophyScrapper", desc = "It is given to the courageous victor of the barbarian arena in scrapper difficulty. Awarded to %s." },
	[3] = { uid = 3266, itemId = 5805, storageKey = "TrophyWarlord", desc = "It is given to the courageous victor of the barbarian arena in warlord difficulty. Awarded to %s." },
}

local DOOR_KEYS = {
	[1] = "GreenhornDoor",
	[2] = "ScrapperDoor",
	[3] = "WarlordDoor",
}

local QUEST_LOG_KEYS = {
	[1] = "QuestLogGreenhorn",
	[2] = "QuestLogScrapper",
	[3] = "QuestLogWarlord",
}

function QuestArena.expeditionIdForArena(arenaId)
	arenaId = tonumber(arenaId)
	if not arenaId then
		return nil
	end
	return QuestArena.ID_BASE + arenaId
end

function QuestArena.buildSvargrondSpec(arenaId)
	arenaId = tonumber(arenaId)
	if not arenaId or type(ARENA) ~= "table" or not ARENA[arenaId] then
		return nil
	end
	local arena = ARENA[arenaId]
	local b = barb()
	local pits = buildPitsFromStock()
	if #pits < 10 then
		-- PITS may be sparse-keyed; count manually.
		local n = 0
		for i = 1, 10 do
			if pits[i] then
				n = n + 1
			end
		end
		if n < 1 then
			return nil
		end
	end
	local creatures = {}
	for i, name in ipairs(arena.creatures or {}) do
		creatures[i] = name
	end
	local trophyMeta = TROPHY[arenaId]
	local trophyStorage = nil
	if b and trophyMeta and trophyMeta.storageKey then
		trophyStorage = b[trophyMeta.storageKey]
	end
	return {
		arenaId = arenaId,
		name = arena.name,
		fee = arena.price or 0,
		kickTimeSec = (SvargrondArena and SvargrondArena.kickTime) or 600,
		solo = true,
		pits = pits,
		creatures = creatures,
		achievement = arena.achievement,
		rewardUids = REWARD_UIDS[arenaId],
		trophy = trophyMeta and {
			uid = trophyMeta.uid,
			itemId = trophyMeta.itemId,
			storage = trophyStorage,
			desc = trophyMeta.desc,
		} or nil,
		storages = {
			arena = b and b.Arena or 41151,
			pitDoor = b and b.PitDoor or 41152,
			questLog = b and b[QUEST_LOG_KEYS[arenaId]] or nil,
			doorAccess = b and b[DOOR_KEYS[arenaId]] or nil,
			arenaId = arenaId,
		},
	}
end

function QuestArena.specForExpeditionId(expeditionId)
	local id = tonumber(expeditionId)
	if not id then
		return nil
	end
	local arenaId = id - QuestArena.ID_BASE
	if arenaId >= 1 and arenaId <= 3 then
		return QuestArena.buildSvargrondSpec(arenaId)
	end
	return nil
end

local function alreadyInCatalog(id)
	if not ExpeditionConfig or not ExpeditionConfig.getById then
		return false
	end
	return ExpeditionConfig.getById(id, "arena") ~= nil or ExpeditionConfig.getById(id) ~= nil
end

function QuestArena.registerExpeditions()
	if registered then
		return true
	end
	if not ExpeditionConfig or not ExpeditionConfig.Catalog then
		return false
	end
	if type(ARENA) ~= "table" or type(PITS) ~= "table" then
		logger.warn("[QuestArena] stock ARENA/PITS missing — skip registration")
		return false
	end
	local count = 0
	for arenaId = 1, 3 do
		local spec = QuestArena.buildSvargrondSpec(arenaId)
		local id = QuestArena.expeditionIdForArena(arenaId)
		if spec and id and not alreadyInCatalog(id) then
			local pit1 = spec.pits[1]
			local center = pit1 and pit1.center or { x = 32210, y = 31098, z = 7 }
			local boundary = pit1 and pitBoundary(pit1) or nil
			local firstCreature = spec.creatures[1]
			local info = firstCreature and CreatureInfo and CreatureInfo.get and CreatureInfo.get(firstCreature)
			local creatureId = info and tonumber(info.creatureId) or nil
			local entry = {
				id = id,
				kind = "hunt",
				role = "arena",
				name = "Barbarian Arena: " .. spec.name,
				exclusiveArena = true,
				arenaId = arenaId,
				arenaSpec = spec,
				levelMin = 1,
				recommendedLevel = arenaId == 1 and 20 or (arenaId == 2 and 50 or 80),
				creatureId = creatureId,
				creatureIds = creatureId and { creatureId } or nil,
				center = { x = center.x, y = center.y, z = center.z },
				boundary = boundary,
				floors = { center.z },
				maxPlayers = 1,
				minPlayers = 1,
				lureMax = 1,
				score = 2000 + arenaId,
				cave = { lure = 1, waypoints = {} },
			}
			for _, pit in ipairs(spec.pits) do
				if pit and pit.center then
					local waypoints = entry.cave.waypoints
					waypoints[#waypoints + 1] = {
						x = pit.center.x,
						y = pit.center.y,
						z = pit.center.z,
						spot = true,
					}
				end
			end
			ExpeditionConfig.Catalog[#ExpeditionConfig.Catalog + 1] = entry
			count = count + 1
		end
	end
	registered = true
	logger.info("[QuestArena] registered {} exclusive arena expeditions", count)
	return true
end

function QuestArena.canJoin(player, catalog)
	if not catalog or not catalog.exclusiveArena then
		return true
	end
	if not player then
		return false, "Invalid player."
	end
	local spec = catalog.arenaSpec or QuestArena.specForExpeditionId(catalog.id)
	local stor = spec and spec.storages
	if not stor or not stor.pitDoor or not stor.arena then
		return false, "Arena data missing."
	end
	local arenaId = stor.arenaId or catalog.arenaId
	local curArena = player:getStorageValue(stor.arena)
	if curArena < 1 then
		curArena = 1
	end
	if curArena ~= arenaId then
		return false, "This arena difficulty is not available."
	end
	local pit = player:getStorageValue(stor.pitDoor)
	if pit < 1 or pit > 10 then
		return false, "Accept the arena challenge (pay the fee) from Quests first."
	end
	return true
end

function QuestArena.isActive(player, arenaId)
	local spec = QuestArena.buildSvargrondSpec(arenaId)
	if not player or not spec then
		return false
	end
	local stor = spec.storages
	local curArena = player:getStorageValue(stor.arena)
	if curArena < 1 then
		curArena = 1
	end
	if curArena ~= arenaId then
		return false
	end
	local pit = player:getStorageValue(stor.pitDoor)
	return pit >= 1 and pit <= 10
end

-- Patch stock helpers so private-instance creatures are ignored on shared tiles.
function QuestArena.patchStockHelpers()
	if not SvargrondArena then
		return
	end
	if SvargrondArena._idleotPatched then
		return
	end
	SvargrondArena._idleotPatched = true

	local oldGet = SvargrondArena.getPitCreatures
	function SvargrondArena.getPitCreatures(pitId)
		local list = oldGet and oldGet(pitId) or {}
		local out = {}
		for i = 1, #list do
			local c = list[i]
			if c and not isPrivateInstance(c) then
				out[#out + 1] = c
			end
		end
		return out
	end

	local oldReset = SvargrondArena.resetPit
	function SvargrondArena.resetPit(pitId)
		if not PITS or not PITS[pitId] then
			return
		end
		for x = PITS[pitId].fromPos.x, PITS[pitId].toPos.x do
			for y = PITS[pitId].fromPos.y, PITS[pitId].toPos.y do
				for z = PITS[pitId].fromPos.z, PITS[pitId].toPos.z do
					local tile = Tile({ x = x, y = y, z = z })
					if tile then
						local movableItem = tile:getThing(255)
						if movableItem and movableItem:isItem() then
							local itemType = ItemType(movableItem:getId())
							local skipItem = false
							if isPrivateInstance(movableItem) then
								skipItem = true
							end
							if not skipItem and itemType and itemType:isMovable() and not table.contains(SvargrondArena.itemsNotErasable, movableItem:getId()) then
								movableItem:remove()
							end
						end
						local creatures = tile.getCreatures and tile:getCreatures() or nil
						if type(creatures) == "table" then
							for _, creature in ipairs(creatures) do
								if creature and creature:isMonster() and not isPrivateInstance(creature) then
									creature:remove()
								end
							end
						else
							local creature = tile:getTopCreature()
							if creature and creature:isMonster() and not isPrivateInstance(creature) then
								creature:remove()
							end
						end
					end
				end
			end
		end

		local pillarTile = Tile(PITS[pitId].pillar)
		if pillarTile then
			local teleportItem = pillarTile:getItemById(SvargrondArena.itemTeleport)
			if teleportItem then
				if not isPrivateInstance(teleportItem) then
					teleportItem:remove()
				end
			end
			local pillarItem = pillarTile:getItemById(SvargrondArena.itemPillar)
			if not pillarItem then
				-- The pillar is a map-template item shared by every open-world channel.
				Game.createItem(SvargrondArena.itemPillar, 1, PITS[pitId].pillar, Instance.WORLD)
			end
		end
	end

	-- Stock SvargrondArenaBossDeath cannot be replaced via CreatureEvent:register()
	-- after load (Crystal keeps the first loaded script). Private-instance guard lives
	-- in idleot/.../creaturescripts_arena_kill.lua.patch instead.
end
