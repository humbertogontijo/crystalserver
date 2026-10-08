-- ============================================================================
-- Echo Raids / Echo Wardens
-- CIP-aligned: three raid outcomes, 3× Warden HP, empower aura, World-layer
-- subarea portals with door-style per-instance claim, 10 min raid TTL.
-- Each raid owns a Scope (spawn trickle, aura, TTL despawn) that ends once its last
-- creature leaves the map; the outline is engine state (monster:setEchoGlow).
-- ============================================================================

EchoWarden = EchoWarden or {}

-- ----------------------------- TUNABLES -------------------------------------
EchoWarden.PORTAL_ITEM_ID = 54133
EchoWarden.PORTAL_SPENT_ITEM_ID = 54134 -- per-instance tombstone (hides World-layer template)
EchoWarden.PORTAL_ATTR_KIND = "echoKind"
EchoWarden.PORTAL_ATTR_SHARED = "echoShared" -- "1" = World-layer scheduled/shared portal
EchoWarden.PORTAL_TTL_MS = 120000 -- unused shared/corpse portal cleanup
EchoWarden.SUBAREA_ARM_TTL_MS = 120000 -- how long an World-layer arm stays on the map
EchoWarden.SUBAREA_INTERVAL_MIN_MS = 25 * 60 * 1000
EchoWarden.SUBAREA_INTERVAL_MAX_MS = 35 * 60 * 1000

-- Corpse portal chance (prod CIP-ish rare arm).
EchoWarden.SPAWN_CHANCE_NUM = 100
EchoWarden.SPAWN_CHANCE_DEN = 200000

EchoWarden.REGULAR_PACK_SIZE = 8
EchoWarden.INFLUENCED_PACK_SIZE = 4
EchoWarden.WARDEN_SUPPORT_SIZE = 4
EchoWarden.WARDEN_CHANCE_BASE = 10 -- percent
EchoWarden.WARDEN_CHANCE_BESTIARY = 20 -- percent when activator completed bestiary
-- Remaining non-warden rolls: 70% regular / 30% influenced of the leftover mass
EchoWarden.INFLUENCED_SHARE_OF_NON_WARDEN = 30

EchoWarden.WARDEN_HP_MULT = 3.0
EchoWarden.WARDEN_ATK_MULT = 1.5
EchoWarden.AURA_RANGE = 5
EchoWarden.AURA_MS = 2000
EchoWarden.EMPOWER_DODGE_CHANCE = 15 -- percent chance empowered mobs fully dodge a hit

EchoWarden.SCATTER_RADIUS = 3
EchoWarden.SPAWN_STEP_MS = 400
EchoWarden.RAID_TTL_MS = 10 * 60 * 1000

EchoWarden.STORAGE_IS_WARDEN = 54133
EchoWarden.STORAGE_IS_EMPOWERED = 54134
EchoWarden.KV_SCOPE = "echo_warden"
EchoWarden.KV_COUNT_KEY = "_warden_kills" -- total unique first-kills (achievements)
EchoWarden.KV_DISC_ARM = "_discovery_arm" -- placeId -> true pending

-- CIP charm points by bestiary stars (1★..5★ ≈ Harmless..Challenging)
EchoWarden.CHARMS_BY_STARS = { [0] = 1, [1] = 1, [2] = 2, [3] = 5, [4] = 10, [5] = 30 }
EchoWarden.CATALYST_IDS = { 54266, 51588, 51589 } -- lesser / regular / greater
-- Monk: "15 Echo Warden's Dust" — character-bound forge dust, not a corpse item.
EchoWarden.DUST_AMOUNT = 15
EchoWarden.BASIC_SCROLL_MIN, EchoWarden.BASIC_SCROLL_MAX = 53751, 53774

EchoWarden.STATE_WARDEN = 0
EchoWarden.STATE_EMPOWERED = 1

-- warden monster id -> kind name (trigger.lua reads it on death)
EchoWarden.activeWardens = EchoWarden.activeWardens or {}
-- monster id -> raid; raid = { scope, creatures = { [id] = true }, spawning = n }
local raidOf = {}
EchoWarden._subareaArmed = EchoWarden._subareaArmed or {} -- placeId -> {x,y,z,expires}

function EchoWarden.createRaidMonster(kindName, pos, instanceId)
	if not kindName or not pos then
		return nil
	end
	local id = Instance.normalize(instanceId)
	local monster
	if not Instance.isWorld(id) then
		monster = Game.createMonster(kindName, pos, false, true, nil, id)
	else
		monster = Game.createMonster(kindName, pos, false, true)
	end
	return monster
end

local function track(raid, m)
	raid.creatures[m:getId()] = true
	raidOf[m:getId()] = raid
	m:registerEvent("IdleMonsterDeath")
	m:registerEvent("EchoWardenEmpowerDodge")
	EchoWarden.applyExpeditionMonsterBind(m)
end

--- Match ExpeditionPack.onInstanceMonsterSpawn: never flee; the raid
--- monster has no spawn, so its home is where the anchor stands when it appears.
function EchoWarden.applyExpeditionMonsterBind(m)
	m:runHealth(0)
	local instanceId = Instance.of(m)
	if not Instance.isPrivate(instanceId) then
		return
	end
	local session = ExpeditionManager.getSessionByInstanceId(instanceId)
	if not session then
		return
	end
	local anchor = ExpeditionConfig.getAnchorPlayer(session)
	local home = (anchor and anchor:getPosition()) or session.holdPos or (session.instance and session.instance.entry)
	if home then
		m:setMasterPos(Position(home.x, home.y, home.z))
	end
end

local function endRaid(raid)
	for cid in pairs(raid.creatures) do
		raidOf[cid] = nil
		EchoWarden.activeWardens[cid] = nil
		local m = Monster(cid)
		if m then
			m:remove()
		end
	end
	raid.creatures = {}
	raid.scope:dispose()
end

IdleEvents.on("monster.removed", function(monster)
	local cid = monster:getId()
	local raid = raidOf[cid]
	if not raid then
		return
	end
	raidOf[cid] = nil
	raid.creatures[cid] = nil
	EchoWarden.activeWardens[cid] = nil
	if raid.spawning == 0 and not next(raid.creatures) then
		raid.scope:dispose()
	end
end, "EchoWarden")

function EchoWarden.findItemOnTile(tile, itemId, instanceId)
	if not tile then
		return nil
	end
	local expected = Instance.normalize(instanceId)
	local items = tile:getItems()
	if type(items) == "table" then
		for _, it in ipairs(items) do
			if it and it:getId() == itemId then
				local iid = Instance.of(it)
				if iid == expected then
					return it
				end
			end
		end
	end
	if Instance.isWorld(expected) then
		return tile:getItemById(itemId)
	end
	return nil
end

function EchoWarden.findPortalOnTile(tile, instanceId)
	return EchoWarden.findItemOnTile(tile, EchoWarden.PORTAL_ITEM_ID, instanceId)
end

function EchoWarden.findSpentOnTile(tile, instanceId)
	return EchoWarden.findItemOnTile(tile, EchoWarden.PORTAL_SPENT_ITEM_ID, instanceId)
end

--- Leave a per-instance spent fork so the World-layer portal stays hidden (door-style).
function EchoWarden.claimSharedPortal(pos, playerInstance, liveItem)
	local iid = Instance.normalize(playerInstance)
	if Instance.isWorld(iid) then
		if liveItem then
			liveItem:remove()
		end
		return
	end
	local tile = Tile(pos)
	if EchoWarden.findSpentOnTile(tile, iid) then
		if liveItem and Instance.normalize(liveItem:getInstanceId()) == iid then
			liveItem:remove()
		end
		return
	end
	-- Use path may have already forked a live portal onto this instance.
	if liveItem and Instance.normalize(liveItem:getInstanceId()) == iid then
		liveItem:transform(EchoWarden.PORTAL_SPENT_ITEM_ID)
		return
	end
	local spent = Game.createItem(EchoWarden.PORTAL_SPENT_ITEM_ID, 1, nil, iid)
	if not spent then
		return
	end
	spent:moveTo(pos)
end

--- Activate an echo portal (Use or step-in). Raids always bind to the player's instance.
function EchoWarden.activateFromItem(player, item, position)
	if not player or not item then
		return false
	end
	local itemId = item:getId()
	if itemId == EchoWarden.PORTAL_SPENT_ITEM_ID then
		return true
	end
	local kind = item:getCustomAttribute(EchoWarden.PORTAL_ATTR_KIND)
	local shared = item:getCustomAttribute(EchoWarden.PORTAL_ATTR_SHARED)
	if type(kind) ~= "string" or kind == "" then
		-- Spent / corrupt
		if itemId == EchoWarden.PORTAL_ITEM_ID then
			item:remove()
		end
		return true
	end
	local itemInstance = Instance.of(item)
	local playerInstance = Instance.of(player)
	if not Instance.isWorld(itemInstance) and playerInstance ~= itemInstance then
		return false
	end
	local pos = position
	if not pos then
		pos = item:getPosition()
	end
	if not pos then
		return false
	end
	-- Already claimed this shared arm in this shard
	if (shared == "1" or Instance.isWorld(itemInstance)) and EchoWarden.findSpentOnTile(Tile(pos), playerInstance) then
		return true
	end

	local center = Position(pos.x, pos.y, pos.z)
	local raidInstance = playerInstance
	if shared == "1" or Instance.isWorld(itemInstance) then
		EchoWarden.claimSharedPortal(center, playerInstance, item)
	else
		item:remove()
	end

	center:sendMagicEffect(CONST_ME_AGONY)
	EchoWarden.runRaid(kind, center, raidInstance, player)
	return true
end

function EchoWarden.pickTile(center, radius)
	radius = radius or EchoWarden.SCATTER_RADIUS
	for _ = 1, 12 do
		local dx = math.random(-radius, radius)
		local dy = math.random(-radius, radius)
		local p = Position(center.x + dx, center.y + dy, center.z)
		local tile = Tile(p)
		if tile and tile:getGround() and not tile:hasFlag(TILESTATE_BLOCKSOLID) and not tile:hasFlag(TILESTATE_PROTECTIONZONE) and not tile:hasFlag(TILESTATE_FLOORCHANGE) and not tile:hasFlag(TILESTATE_TELEPORT) then
			return p
		end
	end
	return center
end

function EchoWarden.makeEmpowered(m)
	m:setStorageValue(EchoWarden.STORAGE_IS_EMPOWERED, 1)
	m:setEchoGlow(EchoWarden.STATE_EMPOWERED)
end

function EchoWarden.makeInfluenced(m, stacks)
	stacks = math.max(1, math.min(5, math.floor(tonumber(stacks) or math.random(1, 5))))
	m:setForgeStack(stacks)
	Game.addInfluencedMonster(m)
	EchoWarden.makeEmpowered(m)
end

local function makeWarden(raid, w, kindName)
	w:applyEchoWarden(EchoWarden.WARDEN_HP_MULT, EchoWarden.WARDEN_ATK_MULT)
	w:removeIcon("warden")
	w:setStorageValue(EchoWarden.STORAGE_IS_WARDEN, 1)
	EchoWarden.activeWardens[w:getId()] = kindName
	track(raid, w)
	w:setEchoGlow(EchoWarden.STATE_WARDEN)
end

--- Aura: empower nearby same-name creatures (glow + dodge; no 1.5× HP convert).
local function startAura(raid, wardenId, kindName)
	local handle
	handle = raid.scope:every(EchoWarden.AURA_MS, function()
		local w = Monster(wardenId)
		if not w or w:getHealth() <= 0 then
			raid.scope:cancel(handle)
			return
		end
		local r = EchoWarden.AURA_RANGE
		for _, c in ipairs(Game.getSpectators(w:getPosition(), false, false, r, r, r, r, Instance.of(w))) do
			local m = c:getMonster()
			if m and m:getId() ~= wardenId and m:getName() == kindName and m:getStorageValue(EchoWarden.STORAGE_IS_WARDEN) ~= 1 then
				EchoWarden.makeEmpowered(m)
			end
		end
	end)
end

--- `count` raid monsters, one every SPAWN_STEP_MS.
local function trickleSpawn(raid, kindName, center, instanceId, count, mode)
	raid.spawning = raid.spawning + count
	local function spawnNext()
		raid.spawning = raid.spawning - 1
		local m = EchoWarden.createRaidMonster(kindName, center, instanceId)
		if m then
			track(raid, m)
			if mode == "influenced" then
				EchoWarden.makeInfluenced(m, math.random(1, 5))
			elseif mode == "empowered" then
				EchoWarden.makeEmpowered(m)
			end
		end
		if raid.spawning > 0 then
			raid.scope:after(EchoWarden.SPAWN_STEP_MS, spawnNext)
		end
	end
	spawnNext()
end

function EchoWarden.playerCompletedBestiary(player, kindName)
	if not player or not kindName then
		return false
	end
	local mt = MonsterType(kindName)
	if not mt then
		return false
	end
	local raceId = mt:raceId() or 0
	if raceId <= 0 then
		return false
	end
	local need = 0
	if mt.BestiarytoKill then
		need = mt:BestiarytoKill() or 0
	end
	if need <= 0 then
		return false
	end
	return player:getBestiaryKillCount(raceId) >= need
end

function EchoWarden.rollOutcome(player, kindName)
	local wardenChance = EchoWarden.WARDEN_CHANCE_BASE
	if EchoWarden.playerCompletedBestiary(player, kindName) then
		wardenChance = EchoWarden.WARDEN_CHANCE_BESTIARY
	end
	local roll = math.random(1, 100)
	if roll <= wardenChance then
		return "warden"
	end
	local nonWarden = 100 - wardenChance
	local influencedCut = math.floor(nonWarden * EchoWarden.INFLUENCED_SHARE_OF_NON_WARDEN / 100)
	if (roll - wardenChance) <= influencedCut then
		return "influenced"
	end
	return "regular"
end

function EchoWarden.runRaid(kindName, center, instanceId, player)
	if not kindName or kindName == "" then
		return
	end
	local id = Instance.normalize(instanceId)
	local pos = Position(center.x, center.y, center.z)
	local raid = {
		scope = Scope.new({ name = string.format("echo:%s:%d:%d:%d", id, pos.x, pos.y, pos.z), instanceId = id }),
		creatures = {},
		spawning = 0,
	}
	raid.scope:after(EchoWarden.RAID_TTL_MS, function()
		endRaid(raid)
	end)
	local outcome = EchoWarden.rollOutcome(player, kindName)
	if outcome == "warden" then
		local w = EchoWarden.createRaidMonster(kindName, pos, id)
		if w then
			makeWarden(raid, w, kindName)
			startAura(raid, w:getId(), kindName)
		end
		trickleSpawn(raid, kindName, pos, id, EchoWarden.WARDEN_SUPPORT_SIZE, "empowered")
	elseif outcome == "influenced" then
		trickleSpawn(raid, kindName, pos, id, EchoWarden.INFLUENCED_PACK_SIZE, "influenced")
	else
		trickleSpawn(raid, kindName, pos, id, EchoWarden.REGULAR_PACK_SIZE, "regular")
	end
end

function EchoWarden.spawnPortal(px, py, pz, kindName, instanceId, shared)
	local pos = Position(px, py, pz)
	local tile = Tile(pos)
	if not tile or not tile:getGround() then
		logger.warn("[EchoWarden] spawnPortal aborted: no ground at {},{},{} kind={}", px, py, pz, kindName)
		return false
	end
	local id = Instance.normalize(instanceId)
	-- Replace existing portal on this instance at the tile
	local existing = EchoWarden.findPortalOnTile(tile, id)
	if existing then
		existing:remove()
	end
	local portal = Game.createItem(EchoWarden.PORTAL_ITEM_ID, 1, nil, id)
	if not portal then
		logger.warn("[EchoWarden] spawnPortal aborted: createItem failed kind={} instance={}", kindName, id)
		return false
	end
	portal:moveTo(pos)
	portal:setCustomAttribute(EchoWarden.PORTAL_ATTR_KIND, kindName)
	if shared or Instance.isWorld(id) then
		portal:setCustomAttribute(EchoWarden.PORTAL_ATTR_SHARED, "1")
	end
	pos:sendMagicEffect(CONST_ME_TELEPORT)
	local ttl = (shared or Instance.isWorld(id)) and EchoWarden.SUBAREA_ARM_TTL_MS or EchoWarden.PORTAL_TTL_MS
	addEvent(function(qx, qy, qz, expectedInstanceId)
		local t = Tile(Position(qx, qy, qz))
		local it = EchoWarden.findPortalOnTile(t, expectedInstanceId)
		if it then
			it:remove()
		end
	end, ttl, px, py, pz, id)
	return true
end

function EchoWarden.kindNameFromRaceId(raceId)
	raceId = tonumber(raceId) or 0
	if raceId <= 0 then
		return nil
	end
	local mt = MonsterType(raceId)
	if mt and mt:name() then
		return mt:name()
	end
	return nil
end

function EchoWarden.pickKindAndPosFromCatalog(entry)
	if not entry or type(entry.spawns) ~= "table" or #entry.spawns == 0 then
		return nil, nil
	end
	local spawn = entry.spawns[math.random(1, #entry.spawns)]
	if not spawn then
		return nil, nil
	end
	local kind = EchoWarden.kindNameFromRaceId(spawn.monsterId or spawn.creatureId)
	if not kind and type(entry.creatureIds) == "table" and entry.creatureIds[1] then
		kind = EchoWarden.kindNameFromRaceId(entry.creatureIds[1])
	end
	if not kind then
		return nil, nil
	end
	local pos = Position(spawn.x, spawn.y, spawn.z)
	return kind, pos
end

--- Arm the World-layer portal of hunt place `placeId`; `reschedule` (default true)
--- queues its next arm.
function EchoWarden.armSubareaEcho(placeId, reschedule)
	if reschedule ~= false then
		EchoWarden.scheduleNextSubareaArm(placeId)
	end
	local entry = ExpeditionConfig.getById(placeId, "monster") or ExpeditionConfig.getById(placeId)
	if not entry or entry.role == "boss" or entry.kind == "boss" then
		return
	end
	local kind, pos = EchoWarden.pickKindAndPosFromCatalog(entry)
	if not kind then
		return
	end
	-- Clear prior World-layer portal for this place if we tracked it
	local prev = EchoWarden._subareaArmed[placeId]
	if prev then
		local it = EchoWarden.findPortalOnTile(Tile(Position(prev.x, prev.y, prev.z)), Instance.WORLD)
		if it then
			it:remove()
		end
	end
	if EchoWarden.spawnPortal(pos.x, pos.y, pos.z, kind, Instance.WORLD, true) then
		EchoWarden._subareaArmed[placeId] = { x = pos.x, y = pos.y, z = pos.z, kind = kind }
	end
end

function EchoWarden.scheduleNextSubareaArm(placeId)
	local delay = math.random(EchoWarden.SUBAREA_INTERVAL_MIN_MS, EchoWarden.SUBAREA_INTERVAL_MAX_MS)
	addEvent(EchoWarden.armSubareaEcho, delay, placeId)
end

function EchoWarden.startSubareaScheduler()
	for _, entry in ipairs(ExpeditionConfig.Catalog) do
		if entry.role ~= "boss" and entry.kind ~= "boss" and type(entry.spawns) == "table" and #entry.spawns > 0 then
			EchoWarden.scheduleNextSubareaArm(tostring(entry.id))
		end
	end
end

function EchoWarden.onServerSave()
	local n = 0
	for _, entry in ipairs(ExpeditionConfig.Catalog) do
		if entry.role ~= "boss" and entry.kind ~= "boss" and type(entry.spawns) == "table" and #entry.spawns > 0 then
			n = n + 1
			if n <= 40 then
				addEvent(EchoWarden.armSubareaEcho, 5000 + n * 250, tostring(entry.id), false)
			end
		end
	end
end

--- Discovery: arm a nearby hunt place echo early.
function EchoWarden.onViewpointDiscovered(player)
	if not player then
		return
	end
	local kv = player:kv():scoped(EchoWarden.KV_SCOPE)
	kv:set(EchoWarden.KV_DISC_ARM, true)
	-- Prefer immediate arm of a hunt place near the player if catalog is up.
	do
		local pos = player:getPosition()
		local best, bestDist = nil, nil
		for _, entry in ipairs(ExpeditionConfig.Catalog) do
			if entry and entry.role ~= "boss" and entry.center and type(entry.spawns) == "table" and #entry.spawns > 0 then
				local c = entry.center
				local dx = (c.x or 0) - pos.x
				local dy = (c.y or 0) - pos.y
				local dist = dx * dx + dy * dy
				if not bestDist or dist < bestDist then
					bestDist = dist
					best = entry
				end
			end
		end
		if best then
			addEvent(EchoWarden.armSubareaEcho, 1000, tostring(best.id), false)
		end
	end
end

function EchoWarden.grantDust(player)
	if not player then
		return false
	end
	local amount = EchoWarden.DUST_AMOUNT or 15
	local totalDusts = player:getForgeDusts()
	local limitDusts = player:getForgeDustLevel()
	if totalDusts >= limitDusts then
		player:sendTextMessage(
			MESSAGE_EVENT_ADVANCE,
			string.format(
				"You did not receive %d Echo Warden dust for the Exaltation Forge because you have already reached the maximum of %d dust.",
				amount,
				limitDusts
			)
		)
		return false
	end
	local granted = amount
	if totalDusts + amount > limitDusts then
		granted = limitDusts - totalDusts
	end
	player:addForgeDusts(granted)
	player:sendTextMessage(
		MESSAGE_EVENT_ADVANCE,
		string.format(
			"You received %d Echo Warden dust for the Exaltation Forge. You now have %d out of a maximum of %d dusts.",
			granted,
			player:getForgeDusts(),
			limitDusts
		)
	)
	return true
end

function EchoWarden.grantReward(player, baseKind)
	if not player or not baseKind or baseKind == "" then
		return false
	end
	local kv = player:kv():scoped(EchoWarden.KV_SCOPE)
	if kv:get(baseKind) then
		return false
	end

	local mt = MonsterType(baseKind)
	local stars = (mt and mt:BestiaryStars()) or 0
	local amount = EchoWarden.CHARMS_BY_STARS[stars] or EchoWarden.CHARMS_BY_STARS[0]
	player:addCharmPoints(amount)
	kv:set(baseKind, true)

	local count = tonumber(kv:get(EchoWarden.KV_COUNT_KEY)) or 0
	count = count + 1
	kv:set(EchoWarden.KV_COUNT_KEY, count)
	player:addAchievementProgress("Echo Raid Initiate", 1)
	player:addAchievementProgress("Echo Raid Hunter", 10)
	player:addAchievementProgress("Echo Raid Walker", 25)
	player:addAchievementProgress("Echo Raid Conqueror", 50)

	local raceId = (mt and mt:raceId()) or 0
	if raceId > 0 then
		player:sendLeaderMonsterKilledBanner(raceId, amount)
	end
	player:sendTextMessage(
		MESSAGE_EVENT_ADVANCE,
		string.format("Echo Warden mastery unlocked for %s (+%d Charm Points). Progress: %d kinds.", baseKind, amount, count)
	)
	return true
end
