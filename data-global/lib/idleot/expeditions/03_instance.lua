ExpeditionInstance = {}

--- Reserved channel of {kind, subareaId}: a private layer of that subarea for one session.
--- kind: InstanceKinds key (PvP mode + death rules), subareaId: catalog / region id.
--- owner: session key checked by Instance.isLive(key, owner); tag: engine-side label.
--- Returns the key, or nil and the engine's reason.
function ExpeditionInstance.allocate(kind, subareaId, owner, tag)
	local id, reason = Game.allocateInstance(kind, math.floor(tonumber(subareaId) or 0), {
		private = true,
		owner = owner and tostring(owner) or nil,
		tag = tag and tostring(tag) or nil,
	})
	if not id then
		logger.error("[ExpeditionInstance] allocate failed for {}:{}: {}", tostring(kind), tostring(subareaId), tostring(reason))
		return nil, reason
	end
	InstanceKinds.apply(id)
	return id
end

--- Release a reserved channel; owners clean up on "instance.released".
function ExpeditionInstance.free(instanceId)
	if instanceId == nil or Instance.isWorld(instanceId) then
		return
	end
	Game.releaseInstance(instanceId)
end

--- Declared floors only (spawn/center/boundary z). Missing z is outside the instance.
function ExpeditionInstance.floorsFromSpec(spec, fallbackZ)
	spec = spec or {}
	local set = {}
	local list = {}
	local function add(z)
		z = math.floor(tonumber(z) or -1)
		if z < 0 or z > 15 or set[z] then
			return
		end
		set[z] = true
		list[#list + 1] = z
	end
	if type(spec.floors) == "table" then
		for _, z in ipairs(spec.floors) do
			add(z)
		end
	end
	if #list == 0 then
		if type(spec.spawns) == "table" then
			for _, spawn in ipairs(spec.spawns) do
				if type(spawn) == "table" then
					add(spawn.z)
				end
			end
		end
		if type(spec.center) == "table" then
			add(spec.center.z)
		end
		if type(spec.boundary) == "table" then
			add(spec.boundary.z)
		end
	end
	add(fallbackZ)
	table.sort(list)
	return list, set
end

function ExpeditionInstance.hasFloor(instance, z)
	if not instance then
		return false
	end
	if not instance.floorSet then
		return true
	end
	return instance.floorSet[math.floor(tonumber(z) or -1)] == true
end

function ExpeditionInstance.contains(instance, pos)
	if not instance or not pos then
		return false
	end
	if not ExpeditionInstance.hasFloor(instance, pos.z) then
		return false
	end
	if instance.occupancy then
		return CombatGeo.occupancyContains(instance.occupancy, pos.x, pos.y)
	end
	local origin = instance.origin
	if not origin then
		return false
	end
	local width = instance.width or 0
	local height = instance.height or 0
	return pos.x >= origin.x
		and pos.x < origin.x + width
		and pos.y >= origin.y
		and pos.y < origin.y + height
end

--- Living players currently sharing this instance id.
--- opts.excludeIds: optional set of player ids to ignore (e.g. mid-death).
--- opts.excludeCompanions: ignore headless companions (wipe when no humans remain).
function ExpeditionInstance.hasLivingPlayers(instance, opts)
	opts = opts or {}
	if not instance or not instance.instanceId then
		return false
	end
	for _, player in ipairs(Game.getInstanceMembers(instance.instanceId)) do
		if player:getHealth() > 0 then
			local id = player:getId()
			if opts.excludeIds and opts.excludeIds[id] then
				-- skip
			elseif opts.excludeCompanions and Alts and Alts.isCompanion and Alts.isCompanion(player) then
				-- skip
			else
				return true
			end
		end
	end
	return false
end

local function loadOccupancy(opts)
	if type(opts) ~= "table" then
		return nil
	end
	if type(opts.occupancy) == "table" then
		return opts.occupancy
	end
	-- Prefer masks already registered at InstanceWorld startup.
	local huntId = tonumber(opts.id)
	if huntId and InstanceWorld and InstanceWorld.occupancyByHuntId then
		local cached = InstanceWorld.occupancyByHuntId[huntId]
		if cached then
			return cached
		end
	end
	local subareaId = tonumber(opts.subareaId) or huntId
	if subareaId and InstanceWorld and InstanceWorld.occupancyBySubarea then
		local cached = InstanceWorld.occupancyBySubarea[subareaId]
		if cached then
			return cached
		end
	end
	local file = opts.overviewFile
	local b = opts.boundary
	if type(file) ~= "string" or file == "" or type(b) ~= "table" then
		return nil
	end
	local ox, oy = tonumber(b.x), tonumber(b.y)
	if not ox or not oy then
		return nil
	end
	local path = ExpeditionConfig.subareaMaskPath and ExpeditionConfig.subareaMaskPath(file)
	if not path then
		return nil
	end
	return Game.loadOccupancyMask(path, ox, oy)
end

--- Resolve world center: catalog.center, raid arena table, or opts.center.
local function resolveCenter(opts)
	if type(opts) == "table" and opts.x and opts.y and opts.z then
		return opts
	end
	if type(opts) ~= "table" then
		return nil
	end
	if opts.center and opts.center.x then
		return opts.center
	end
	local region = opts.region or opts.id
	if region and ExpeditionConfig.RaidArenaCenters and ExpeditionConfig.RaidArenaCenters[region] then
		return ExpeditionConfig.RaidArenaCenters[region]
	end
	if opts.id then
		local entry = ExpeditionConfig.getById(opts.id)
		if entry and entry.center then
			return entry.center
		end
	end
	if region then
		local entry = ExpeditionConfig.getById(region)
		if entry and entry.center then
			return entry.center
		end
	end
	return nil
end

--- Bind a private instance id to the live hunt/raid tiles (no clone).
function ExpeditionInstance.build(instanceId, opts, _seed, _kind)
	local center = resolveCenter(opts)
	if not center then
		return nil, "missing expedition center"
	end

	local occupancy = loadOccupancy(opts)
	local boundary = type(opts) == "table" and opts.boundary or nil
	local mapW = (type(boundary) == "table" and tonumber(boundary.w)) or 17
	local mapH = (type(boundary) == "table" and tonumber(boundary.h)) or 17
	local originX = (type(boundary) == "table" and tonumber(boundary.x)) or (center.x - math.floor(mapW / 2))
	local originY = (type(boundary) == "table" and tonumber(boundary.y)) or (center.y - math.floor(mapH / 2))
	local origin = Position(originX, originY, center.z)
	local entry = Position(center.x, center.y, center.z)
	local region = type(opts) == "table" and (opts.region or opts.id) or nil
	local floors, floorSet = ExpeditionInstance.floorsFromSpec(opts, center.z)
	if InstanceWorld and InstanceWorld.rememberFloors then
		InstanceWorld.rememberFloors(instanceId, floorSet)
	end

	local instance = {
		instanceId = instanceId,
		slot = instanceId,
		origin = origin,
		width = mapW,
		height = mapH,
		mapWidth = mapW,
		mapHeight = mapH,
		entry = entry,
		region = region,
		sourceCenter = Position(center.x, center.y, center.z),
		occupancy = occupancy,
		boundary = boundary,
		floors = floors,
		floorSet = floorSet,
	}
	-- Hunts arrive on the catalog entry (flood landing / resolved pin); center is hold 1.
	local arrival = type(opts) == "table" and opts.entry or nil
	if type(arrival) == "table" and arrival.x and arrival.y and arrival.z then
		local pos = Position(tonumber(arrival.x), tonumber(arrival.y), tonumber(arrival.z))
		if ExpeditionInstance.contains(instance, pos) and ExpeditionInstance.hasGround(pos) then
			instance.entry = pos
		end
	end
	local aabb = {
		x = originX,
		y = originY,
		w = mapW,
		h = mapH,
	}
	Game.setInstancePrivateFence(instanceId, occupancy, aabb, floors)
	return instance
end

local function spawnBounds(instance)
	local origin = instance.origin
	if origin and instance.mapWidth and instance.mapHeight then
		return origin.x, origin.x + instance.mapWidth - 1, origin.y, origin.y + instance.mapHeight - 1
	end
	local entry = instance.entry
	if entry then
		return entry.x - 8, entry.x + 8, entry.y - 8, entry.y + 8
	end
	return 0, 0, 0, 0
end

function ExpeditionInstance.hasGround(pos)
	local tile = Tile(pos)
	return tile and tile:getGround() ~= nil
end

local function sweepTile(tile, instanceId)
	if not tile or not instanceId then
		return
	end
	local creatures = tile.getCreatures and tile:getCreatures() or nil
	if type(creatures) == "table" then
		for _, creature in ipairs(creatures) do
			if creature and creature.getInstanceId and creature:getInstanceId() == instanceId then
				if not (creature.isPlayer and creature:isPlayer()) then
					if creature.setDropLoot then
						creature:setDropLoot(false)
					end
					creature:remove()
				end
			end
		end
	end
	local items = tile.getItems and tile:getItems() or nil
	if type(items) == "table" then
		for i = #items, 1, -1 do
			local item = items[i]
			if item and item.getInstanceId and item:getInstanceId() == instanceId then
				item:remove()
			end
		end
	end
end

--- Remove instance-tagged items/creatures so a recycled private id starts clean.
--- Occupancy ON-bits × declared instance floors.
function ExpeditionInstance.sweep(instance)
	if not instance or not instance.instanceId then
		return
	end
	local instanceId = instance.instanceId
	-- Native sweep walks the registered fence; nil means no fence (fall back to the Lua scan).
	if Game.sweepInstance(instanceId) then
		return
	end
	-- Stop instance respawns before sweeping so nothing reappears mid-teardown.
	Game.clearInstanceSpawns(instanceId)
	for _, monster in ipairs(Game.getInstanceMonsters(instanceId)) do
		monster:setDropLoot(false)
		monster:remove()
	end
	for _, npc in ipairs(Game.getNpcs()) do
		if npc and npc.getInstanceId and npc:getInstanceId() == instanceId then
			npc:remove()
		end
	end

	local occ = instance.occupancy
	local ox = occ and tonumber(occ.originX) or (instance.origin and instance.origin.x)
	local oy = occ and tonumber(occ.originY) or (instance.origin and instance.origin.y)
	local w = occ and tonumber(occ.width) or tonumber(instance.width) or 0
	local h = occ and tonumber(occ.height) or tonumber(instance.height) or 0
	if not ox or not oy or w <= 0 or h <= 0 then
		return
	end
	local floors = instance.floors
	if type(floors) ~= "table" or #floors == 0 then
		local z0 = (instance.origin and tonumber(instance.origin.z)) or (instance.entry and tonumber(instance.entry.z)) or 7
		floors = { z0 }
	end
	local bits = occ and occ.bits
	local hasBits = type(bits) == "string" and bits ~= ""
	local function bitOn(i)
		if not hasBits then
			return true
		end
		local b = bits:byte(math.floor(i / 8) + 1)
		if not b then
			return false
		end
		return math.floor(b / (2 ^ (i % 8))) % 2 == 1
	end
	for ly = 0, h - 1 do
		for lx = 0, w - 1 do
			if bitOn(ly * w + lx) then
				local x, y = ox + lx, oy + ly
				for _, z in ipairs(floors) do
					sweepTile(Tile(Position(x, y, z)), instanceId)
				end
			end
		end
	end
end

function ExpeditionInstance.teardown(instance)
	if not instance or instance._tornDown then
		return
	end
	instance._tornDown = true
	ExpeditionInstance.sweep(instance)
	ExpeditionInstance.free(instance.instanceId)
end

--- True while the instance has not been torn down and the engine still owns its key.
--- The key stays on torn-down instances so late callbacks can compare against it.
function ExpeditionInstance.isLive(instance)
	return instance ~= nil and not instance._tornDown and instance.instanceId ~= nil and Instance.isLive(instance.instanceId)
end

local function sameInstance(creature, instanceId)
	if not creature then
		return false
	end
	if instanceId == nil then
		return true
	end
	return not creature.getInstanceId or creature:getInstanceId() == instanceId
end

local function tileBlocksForInstance(tile, instanceId)
	if not tile or not tile.getGround or not tile:getGround() then
		return true
	end
	if instanceId and tile.hasProperty and CONST_PROP_BLOCKSOLID then
		return tile:hasProperty(CONST_PROP_BLOCKSOLID, instanceId)
	end
	return tile.hasFlag and tile:hasFlag(TILESTATE_BLOCKSOLID)
end

local function isWalkable(pos, instanceId)
	local tile = Tile(pos)
	if not tile or tileBlocksForInstance(tile, instanceId) then
		return false
	end
	local creatures = tile.getCreatures and tile:getCreatures() or nil
	if type(creatures) == "table" then
		for _, creature in ipairs(creatures) do
			if sameInstance(creature, instanceId) then
				return false
			end
		end
		return true
	end
	local top = tile.getTopCreature and tile:getTopCreature() or nil
	return not sameInstance(top, instanceId)
end

local function sameTilePos(a, b)
	return a and b and a.x == b.x and a.y == b.y and a.z == b.z
end

function ExpeditionInstance.reservePos(reserved, pos)
	if not reserved or not pos then
		return
	end
	reserved[CombatGeo.posKey(pos)] = true
end

local function isReserved(reserved, pos)
	return reserved and reserved[CombatGeo.posKey(pos)] == true
end

local function canUseSpawnTile(pos, avoid, reserved, instanceId)
	return isWalkable(pos, instanceId) and not sameTilePos(pos, avoid) and not isReserved(reserved, pos)
end

--- Random walkable SQM inside the instance occupancy / AABB.
--- area (optional) {minX, maxX, minY, maxY, z}: sample inside it first (clamped to the instance).
function ExpeditionInstance.randomWalkable(instance, avoid, reserved, area)
	if not instance then
		return nil
	end
	local minX, maxX, minY, maxY = spawnBounds(instance)
	local z = instance.entry and instance.entry.z or (instance.origin and instance.origin.z) or 7
	if type(area) == "table" then
		local aMinX = math.max(minX, tonumber(area.minX) or minX)
		local aMaxX = math.min(maxX, tonumber(area.maxX) or maxX)
		local aMinY = math.max(minY, tonumber(area.minY) or minY)
		local aMaxY = math.min(maxY, tonumber(area.maxY) or maxY)
		local aZ = tonumber(area.z) or z
		if aMinX <= aMaxX and aMinY <= aMaxY and ExpeditionInstance.hasFloor(instance, aZ) then
			for _ = 1, 40 do
				local pos = Position(math.random(aMinX, aMaxX), math.random(aMinY, aMaxY), aZ)
				if ExpeditionInstance.contains(instance, pos) and canUseSpawnTile(pos, avoid, reserved, instance.instanceId) then
					return pos
				end
			end
		end
	end
	for _ = 1, 40 do
		local x = math.random(minX, maxX)
		local y = math.random(minY, maxY)
		local pos = Position(x, y, z)
		if (not instance.occupancy or CombatGeo.occupancyContains(instance.occupancy, x, y)) and canUseSpawnTile(pos, avoid, reserved, instance.instanceId) then
			return pos
		end
	end
	local pivot = avoid or instance.entry
	if pivot then
		local neighbours = {}
		for dx = -1, 1 do
			for dy = -1, 1 do
				if not (dx == 0 and dy == 0) then
					local x, y = pivot.x + dx, pivot.y + dy
					if x >= minX and x <= maxX and y >= minY and y <= maxY then
						local pos = Position(x, y, pivot.z)
						if (not instance.occupancy or CombatGeo.occupancyContains(instance.occupancy, x, y)) and canUseSpawnTile(pos, avoid, reserved, instance.instanceId) then
							neighbours[#neighbours + 1] = pos
						end
					end
				end
			end
		end
		if #neighbours > 0 then
			return neighbours[math.random(1, #neighbours)]
		end
	end
	if instance.entry and canUseSpawnTile(instance.entry, avoid, reserved, instance.instanceId) then
		return instance.entry
	end
	return nil
end

local function collectRingWalkable(center, radius, instance, reserved)
	local minX, maxX, minY, maxY = spawnBounds(instance)
	local candidates = {}
	for dx = -radius, radius do
		for dy = -radius, radius do
			if math.max(math.abs(dx), math.abs(dy)) == radius then
				local x, y = center.x + dx, center.y + dy
				if x >= minX and x <= maxX and y >= minY and y <= maxY then
					local pos = Position(x, y, center.z)
					if (not instance.occupancy or CombatGeo.occupancyContains(instance.occupancy, x, y)) and canUseSpawnTile(pos, nil, reserved, instance.instanceId) then
						candidates[#candidates + 1] = pos
					end
				end
			end
		end
	end
	return candidates
end

-- createMonster(..., instanceId) already binds before placeCreature — do not
-- call setInstanceId here (on-map remap is a client-ghost source).
local function afterCreateMonster(monster, instance)
	local session = nil
	if instance and instance.instanceId and ExpeditionManager and ExpeditionManager.getSessionByInstanceId then
		session = ExpeditionManager.getSessionByInstanceId(instance.instanceId)
	end
	local skipForge = session and session.skipOpenWorldForge == true
	if monster and not skipForge then
		InstanceWorld.applyOpenWorldForge(monster)
	end
	return monster
end

function ExpeditionInstance.createMonsterExclusive(name, preferredPos, instance)
	if not name or not preferredPos then
		return nil
	end
	local instanceId = instance and instance.instanceId or nil
	local monster = Game.createMonster(name, preferredPos, false, false, nil, instanceId)
	if monster then
		return afterCreateMonster(monster, instance)
	end
	if instance then
		local reserved = {}
		ExpeditionInstance.reservePos(reserved, preferredPos)
		for radius = 1, 3 do
			local pos = ExpeditionInstance.randomAttackRangeWalkable(instance, preferredPos, radius, reserved)
			if pos then
				monster = Game.createMonster(name, pos, false, false, nil, instanceId)
				if monster then
					return afterCreateMonster(monster, instance)
				end
				ExpeditionInstance.reservePos(reserved, pos)
			end
		end
		local any = ExpeditionInstance.randomWalkable(instance, preferredPos, reserved)
		if any then
			return afterCreateMonster(Game.createMonster(name, any, false, false, nil, instanceId), instance)
		end
	end
	return afterCreateMonster(Game.createMonster(name, preferredPos, true, false, nil, instanceId), instance)
end

function ExpeditionInstance.randomAttackRangeWalkable(instance, center, radius, reserved)
	if not instance or not center then
		return nil
	end
	radius = math.max(1, tonumber(radius) or 1)

	local candidates = collectRingWalkable(center, radius, instance, reserved)
	if #candidates > 0 then
		return candidates[math.random(1, #candidates)]
	end

	for delta = 1, 3 do
		for _, r in ipairs({ radius - delta, radius + delta }) do
			if r >= 1 then
				candidates = collectRingWalkable(center, r, instance, reserved)
				if #candidates > 0 then
					return candidates[math.random(1, #candidates)]
				end
			end
		end
	end

	return ExpeditionInstance.randomWalkable(instance, center, reserved)
end

--- Broadcast a magic effect only to players in this instance (shared hunt tiles).
function ExpeditionInstance.sendMagicEffect(instance, pos, effect)
	if not pos or not pos.sendMagicEffect or not effect then
		return
	end
	local instanceId = instance and instance.instanceId
	if instanceId == nil or not Game.getSpectators then
		pos:sendMagicEffect(effect)
		return
	end
	local spectators = Game.getSpectators(pos, true, true, 0, 0, 0, 0, instanceId)
	if type(spectators) ~= "table" then
		return
	end
	for _, player in ipairs(spectators) do
		if player then
			pos:sendMagicEffect(effect, player)
		end
	end
end
