-- ============================================================================
-- Echo Raids / Echo Wardens - shared library (pure Lua)
-- CIP-aligned: three raid outcomes, 3× Warden HP, empower aura, World-layer
-- subarea portals with door-style per-instance claim, 10 min raid TTL.
-- Loaded from data-global/lib/core/load.lua before revscriptsys scripts.
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
EchoWarden.USE_CPP_ATK = true

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
EchoWarden.GLOW_RANGE = 11
EchoWarden.GLOW_REFRESH_MS = 400

EchoWarden.activeWardens = EchoWarden.activeWardens or {}
EchoWarden.activeEmpowered = EchoWarden.activeEmpowered or {}
EchoWarden.activeRaidCreatures = EchoWarden.activeRaidCreatures or {}
EchoWarden._glowLoop = false
EchoWarden._subareaArmed = EchoWarden._subareaArmed or {} -- placeId -> {x,y,z,expires}

function EchoWarden.sendEffect(pos, effect, instanceId)
	if not pos or not effect then
		return
	end
	local id = Instance.normalize(instanceId)
	if Instance.isWorld(id) or not Game.getSpectators then
		pos:sendMagicEffect(effect)
		return
	end
	for _, player in ipairs(Game.getSpectators(pos, true, true, 0, 0, 0, 0, id) or {}) do
		if player then
			pos:sendMagicEffect(effect, player)
		end
	end
end

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

function EchoWarden.trackRaidCreature(m, raidToken)
	if not m then
		return
	end
	EchoWarden.activeRaidCreatures[m:getId()] = raidToken or true
	EchoWarden.registerExpeditionDeath(m)
	if m.registerEvent then
		m:registerEvent("EchoWardenEmpowerDodge")
	end
	-- Same bind as ExpeditionPack instance spawns when inside a private hunt shard.
	EchoWarden.applyExpeditionMonsterBind(m)
end

--- Match ExpeditionPack.onInstanceMonsterSpawn: never flee; the raid
--- monster has no spawn, so its home is where the anchor stands when it appears.
function EchoWarden.applyExpeditionMonsterBind(m)
	if not m then
		return
	end
	if m.runHealth then
		m:runHealth(0)
	end
	local instanceId = Instance.of(m)
	if not Instance.isPrivate(instanceId) then
		return
	end
	local session = ExpeditionManager and ExpeditionManager.getSessionByInstanceId and ExpeditionManager.getSessionByInstanceId(instanceId)
	if not session then
		return
	end
	local anchor = ExpeditionConfig and ExpeditionConfig.getAnchorPlayer and ExpeditionConfig.getAnchorPlayer(session)
	local home = (anchor and anchor:getPosition()) or session.holdPos or (session.instance and session.instance.entry)
	if m.setMasterPos and home then
		m:setMasterPos(Position(home.x, home.y, home.z))
	end
end

function EchoWarden.scheduleRaidDespawn(raidToken, instanceId)
	addEvent(function(token, iid)
		for cid, t in pairs(EchoWarden.activeRaidCreatures) do
			if t == token then
				local m = Monster(cid)
				if m and not m:isRemoved() then
					m:remove()
				end
				EchoWarden.activeRaidCreatures[cid] = nil
				EchoWarden.activeWardens[cid] = nil
				EchoWarden.activeEmpowered[cid] = nil
			end
		end
	end, EchoWarden.RAID_TTL_MS, raidToken, Instance.normalize(instanceId))
end

function EchoWarden.findItemOnTile(tile, itemId, instanceId)
	if not tile then
		return nil
	end
	local expected = Instance.normalize(instanceId)
	local items = tile.getItems and tile:getItems() or nil
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
	if Instance.isWorld(expected) and tile.getItemById then
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
	local kind = item.getCustomAttribute and item:getCustomAttribute(EchoWarden.PORTAL_ATTR_KIND) or nil
	local shared = item.getCustomAttribute and item:getCustomAttribute(EchoWarden.PORTAL_ATTR_SHARED) or nil
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
	if not pos and item.getPosition then
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

	EchoWarden.sendEffect(center, CONST_ME_AGONY, raidInstance)
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

function EchoWarden.registerExpeditionDeath(m)
	if m and m.registerEvent then
		m:registerEvent("IdleMonsterDeath")
	end
end

function EchoWarden.makeEmpowered(m)
	if not m then
		return
	end
	if m:getStorageValue(EchoWarden.STORAGE_IS_EMPOWERED) ~= 1 then
		m:setStorageValue(EchoWarden.STORAGE_IS_EMPOWERED, 1)
	end
	EchoWarden.activeEmpowered[m:getId()] = true
	EchoWarden.sendCreatureGlow(m, EchoWarden.STATE_EMPOWERED)
	EchoWarden.ensureGlowLoop()
end

function EchoWarden.makeInfluenced(m, stacks)
	if not m then
		return
	end
	stacks = math.max(1, math.min(5, math.floor(tonumber(stacks) or math.random(1, 5))))
	if m.setForgeStack then
		m:setForgeStack(stacks)
	end
	if Game.addInfluencedMonster then
		Game.addInfluencedMonster(m)
	end
	EchoWarden.makeEmpowered(m)
end

---@param creature Creature
---@param state number 0=Echo Warden, 1=Empowered
function EchoWarden.sendCreatureGlow(creature, state)
	if not creature then
		return
	end
	local cid = creature:getId()
	local pos = creature:getPosition()
	if not pos then
		return
	end
	local r = EchoWarden.GLOW_RANGE
	local instanceId = Instance.of(creature)
	for _, spec in ipairs(Game.getSpectators(pos, false, true, r, r, r, r, instanceId)) do
		local msg = NetworkMessage()
		msg:addByte(0x8B)
		msg:addU32(cid)
		msg:addByte(0x0f)
		msg:addByte(1)
		msg:addByte(state)
		msg:sendToPlayer(spec)
	end
end

function EchoWarden.glowRefresh()
	local any = false
	for id in pairs(EchoWarden.activeWardens) do
		local w = Monster(id)
		if w and not w:isRemoved() and w:getHealth() > 0 then
			EchoWarden.sendCreatureGlow(w, EchoWarden.STATE_WARDEN)
			any = true
		else
			EchoWarden.activeWardens[id] = nil
		end
	end
	for id in pairs(EchoWarden.activeEmpowered) do
		local m = Monster(id)
		if m and not m:isRemoved() and m:getHealth() > 0 then
			EchoWarden.sendCreatureGlow(m, EchoWarden.STATE_EMPOWERED)
			any = true
		else
			EchoWarden.activeEmpowered[id] = nil
		end
	end
	if any then
		addEvent(EchoWarden.glowRefresh, EchoWarden.GLOW_REFRESH_MS)
	else
		EchoWarden._glowLoop = false
	end
end

function EchoWarden.ensureGlowLoop()
	if not EchoWarden._glowLoop then
		EchoWarden._glowLoop = true
		EchoWarden.glowRefresh()
	end
end

function EchoWarden.makeWarden(w, kindName, raidToken)
	if not w then
		return
	end
	if EchoWarden.USE_CPP_ATK and w.applyEchoWarden then
		w:applyEchoWarden(EchoWarden.WARDEN_HP_MULT, EchoWarden.WARDEN_ATK_MULT)
		w:removeIcon("warden")
	else
		w:setMaxHealth(math.floor(w:getMaxHealth() * EchoWarden.WARDEN_HP_MULT))
		w:setHealth(w:getMaxHealth())
	end
	w:setStorageValue(EchoWarden.STORAGE_IS_WARDEN, 1)
	EchoWarden.activeWardens[w:getId()] = kindName
	EchoWarden.trackRaidCreature(w, raidToken)
	EchoWarden.sendCreatureGlow(w, EchoWarden.STATE_WARDEN)
	EchoWarden.ensureGlowLoop()
end

--- Aura: empower nearby same-name creatures (glow + dodge; no 1.5× HP convert).
function EchoWarden.aura(wardenId, kindName)
	local w = Monster(wardenId)
	if not w or w:isRemoved() or w:getHealth() <= 0 then
		EchoWarden.activeWardens[wardenId] = nil
		return
	end
	local p = w:getPosition()
	local r = EchoWarden.AURA_RANGE
	local instanceId = Instance.of(w)
	for _, c in ipairs(Game.getSpectators(p, false, false, r, r, r, r, instanceId)) do
		local m = c:getMonster()
		if m and m:getId() ~= wardenId and m:getName() == kindName and m:getStorageValue(EchoWarden.STORAGE_IS_WARDEN) ~= 1 then
			EchoWarden.makeEmpowered(m)
		end
	end
	addEvent(EchoWarden.aura, EchoWarden.AURA_MS, wardenId, kindName)
end

function EchoWarden.trickleSpawn(kindName, cx, cy, cz, remaining, stepMs, instanceId, mode, raidToken)
	if remaining <= 0 then
		return
	end
	local m = EchoWarden.createRaidMonster(kindName, Position(cx, cy, cz), instanceId)
	if m then
		EchoWarden.trackRaidCreature(m, raidToken)
		if mode == "influenced" then
			EchoWarden.makeInfluenced(m, math.random(1, 5))
		elseif mode == "empowered" then
			EchoWarden.makeEmpowered(m)
		end
	end
	addEvent(EchoWarden.trickleSpawn, stepMs, kindName, cx, cy, cz, remaining - 1, stepMs, instanceId, mode, raidToken)
end

function EchoWarden.playerCompletedBestiary(player, kindName)
	if not player or not kindName then
		return false
	end
	local mt = MonsterType(kindName)
	if not mt or not player.getBestiaryKillCount then
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
	local cx, cy, cz = center.x, center.y, center.z
	local step = EchoWarden.SPAWN_STEP_MS
	local id = Instance.normalize(instanceId)
	local outcome = EchoWarden.rollOutcome(player, kindName)
	local raidToken = string.format("%s:%d:%d:%d:%d", id, cx, cy, cz, os.time())
	if outcome == "warden" then
		local w = EchoWarden.createRaidMonster(kindName, Position(cx, cy, cz), id)
		if w then
			EchoWarden.makeWarden(w, kindName, raidToken)
			addEvent(EchoWarden.aura, EchoWarden.AURA_MS, w:getId(), kindName)
		end
		EchoWarden.trickleSpawn(kindName, cx, cy, cz, EchoWarden.WARDEN_SUPPORT_SIZE, step, id, "empowered", raidToken)
	elseif outcome == "influenced" then
		EchoWarden.trickleSpawn(kindName, cx, cy, cz, EchoWarden.INFLUENCED_PACK_SIZE, step, id, "influenced", raidToken)
	else
		EchoWarden.trickleSpawn(kindName, cx, cy, cz, EchoWarden.REGULAR_PACK_SIZE, step, id, "regular", raidToken)
	end

	EchoWarden.scheduleRaidDespawn(raidToken, id)
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
	EchoWarden.sendEffect(pos, CONST_ME_TELEPORT, id)
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
	if raceId <= 0 or not MonsterType then
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

function EchoWarden.armSubareaEcho(placeId, reschedule)
	placeId = tostring(placeId or "")
	if reschedule == nil then
		reschedule = true
	end
	if placeId == "" or not ExpeditionConfig or not ExpeditionConfig.getById then
		if reschedule then
			EchoWarden.scheduleNextSubareaArm(placeId)
		end
		return
	end
	local entry = ExpeditionConfig.getById(placeId, "monster") or ExpeditionConfig.getById(placeId)
	if not entry or entry.role == "boss" or entry.kind == "boss" then
		if reschedule then
			EchoWarden.scheduleNextSubareaArm(placeId)
		end
		return
	end
	local kind, pos = EchoWarden.pickKindAndPosFromCatalog(entry)
	if not kind or not pos then
		if reschedule then
			EchoWarden.scheduleNextSubareaArm(placeId)
		end
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
	if EchoWarden.spawnPortal(pos.x, pos.y, pos.z, kind, 0, true) then
		EchoWarden._subareaArmed[placeId] = { x = pos.x, y = pos.y, z = pos.z, kind = kind }
	end
	if reschedule then
		EchoWarden.scheduleNextSubareaArm(placeId)
	end
end

function EchoWarden.scheduleNextSubareaArm(placeId)
	placeId = tostring(placeId or "")
	if placeId == "" then
		return
	end
	local delay = math.random(EchoWarden.SUBAREA_INTERVAL_MIN_MS, EchoWarden.SUBAREA_INTERVAL_MAX_MS)
	addEvent(EchoWarden.armSubareaEcho, delay, placeId)
end

function EchoWarden.startSubareaScheduler()
	if not ExpeditionConfig or type(ExpeditionConfig.Catalog) ~= "table" then
		logger.warn("[EchoWarden] subarea scheduler skipped: no ExpeditionConfig.Catalog")
		return
	end
	local n = 0
	for _, entry in ipairs(ExpeditionConfig.Catalog) do
		if entry and entry.role ~= "boss" and entry.kind ~= "boss" and type(entry.spawns) == "table" and #entry.spawns > 0 then
			local placeId = tostring(entry.id)
			local delay = math.random(EchoWarden.SUBAREA_INTERVAL_MIN_MS, EchoWarden.SUBAREA_INTERVAL_MAX_MS)
			addEvent(EchoWarden.armSubareaEcho, delay, placeId)
			n = n + 1
		end
	end
end

function EchoWarden.onServerSave()
	if not ExpeditionConfig or type(ExpeditionConfig.Catalog) ~= "table" then
		return
	end
	local n = 0
	for _, entry in ipairs(ExpeditionConfig.Catalog) do
		if entry and entry.role ~= "boss" and entry.kind ~= "boss" and type(entry.spawns) == "table" and #entry.spawns > 0 then
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
	if ExpeditionConfig and type(ExpeditionConfig.Catalog) == "table" then
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
	if not player or not player.addForgeDusts then
		return false
	end
	local amount = EchoWarden.DUST_AMOUNT or 15
	local totalDusts = player:getForgeDusts()
	local limitDusts = player:getForgeDustLevel()
	if totalDusts >= limitDusts then
		if player.sendTextMessage then
			player:sendTextMessage(
				MESSAGE_EVENT_ADVANCE,
				string.format(
					"You did not receive %d Echo Warden dust for the Exaltation Forge because you have already reached the maximum of %d dust.",
					amount,
					limitDusts
				)
			)
		end
		return false
	end
	local granted = amount
	if totalDusts + amount > limitDusts then
		granted = limitDusts - totalDusts
	end
	player:addForgeDusts(granted)
	if player.sendTextMessage then
		player:sendTextMessage(
			MESSAGE_EVENT_ADVANCE,
			string.format(
				"You received %d Echo Warden dust for the Exaltation Forge. You now have %d out of a maximum of %d dusts.",
				granted,
				player:getForgeDusts(),
				limitDusts
			)
		)
	end
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
	if player.addCharmPoints then
		player:addCharmPoints(amount)
	else
		player:addMinorCharmEchoes(amount)
	end
	kv:set(baseKind, true)

	local count = tonumber(kv:get(EchoWarden.KV_COUNT_KEY)) or 0
	count = count + 1
	kv:set(EchoWarden.KV_COUNT_KEY, count)
	if player.addAchievementProgress then
		player:addAchievementProgress("Echo Raid Initiate", 1)
		player:addAchievementProgress("Echo Raid Hunter", 10)
		player:addAchievementProgress("Echo Raid Walker", 25)
		player:addAchievementProgress("Echo Raid Conqueror", 50)
	end

	local raceId = (mt and mt:raceId()) or 0
	if raceId > 0 and player.sendLeaderMonsterKilledBanner then
		player:sendLeaderMonsterKilledBanner(raceId, amount)
	end
	if player.sendTextMessage then
		player:sendTextMessage(
			MESSAGE_EVENT_ADVANCE,
			string.format("Echo Warden mastery unlocked for %s (+%d Charm Points). Progress: %d kinds.", baseKind, amount, count)
		)
	end
	return true
end
