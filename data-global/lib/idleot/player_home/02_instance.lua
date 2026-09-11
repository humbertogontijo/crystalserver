PlayerHome = PlayerHome or {}
PlayerHomeInstance = PlayerHomeInstance or {}

local templateReady = false
local sharedHouse = nil
local sharedZone = nil

local function sharedOrigin()
	return Position(
		PlayerHomeConfig.INSTANCE_BASE_X,
		PlayerHomeConfig.INSTANCE_BASE_Y,
		PlayerHomeConfig.INSTANCE_Z
	)
end

local function wallId(lx, ly, outer)
	local max = outer - 1
	local onN, onS = ly == 0, ly == max
	local onW, onE = lx == 0, lx == max
	if not (onN or onS or onW or onE) then
		return nil
	end
	if onN and onW then
		return PlayerHomeConfig.WALL_TL
	end
	if onN and onE then
		return PlayerHomeConfig.WALL_TR
	end
	if onS and onW then
		return PlayerHomeConfig.WALL_BL
	end
	if onS and onE then
		return PlayerHomeConfig.WALL_BR
	end
	if onN or onS then
		return PlayerHomeConfig.WALL_H
	end
	return PlayerHomeConfig.WALL_V
end

local function itemMatchesInstance(item, instanceId)
	if not item or instanceId == nil then
		return false
	end
	if not item.getInstanceId then
		return false
	end
	return item:getInstanceId() == instanceId
end

local function tileItemsForInstance(tile, instanceId)
	local items = tile and tile:getItems() or nil
	if not items then
		return nil
	end
	local out = {}
	for _, it in ipairs(items) do
		if itemMatchesInstance(it, instanceId) then
			out[#out + 1] = it
		end
	end
	return out
end

local function ensureTemplateItemAt(pos, itemId)
	if not sharedHouse or not pos or not itemId then
		return
	end
	sharedHouse:addTile(pos)
	local tile = Tile(pos)
	if not tile then
		return
	end
	local items = tile:getItems()
	if items then
		for _, it in ipairs(items) do
			if it:getId() == itemId then
				return
			end
		end
	end
	Game.createItem(itemId, 1, pos)
end

local function ensureGroundOrWall(pos, itemId)
	if not sharedHouse or not itemId then
		return
	end
	sharedHouse:addTile(pos)
	local tile = Tile(pos)
	if not tile then
		return
	end
	local ground = tile:getGround()
	if not ground then
		Game.createItem(itemId, 1, pos)
	elseif ground:getId() ~= itemId then
		ground:transform(itemId)
	end
end

--- Stamp shared home template once at server start (instance 0: floors, walls, locker).
function PlayerHomeInstance.ensureTemplate()
	if templateReady then
		return sharedHouse
	end

	local origin = sharedOrigin()
	local floor = PlayerHomeConfig.FLOOR_SIZE
	local outer = PlayerHomeConfig.OUTER_SIZE
	local z = origin.z
	local floorId = PlayerHomeConfig.FLOOR_ID

	local house = Game.createHouse(PlayerHomeConfig.HOUSE_ID)
	if not house then
		logger.error("[PlayerHome] failed to create ephemeral house {}", PlayerHomeConfig.HOUSE_ID)
		return nil
	end
	house:setEphemeral(true)
	house:setName("Personal Home")
	house:setSize(outer * outer)

	local entry = Position(
		origin.x + 1 + math.floor(floor / 2),
		origin.y + 1 + math.floor(floor / 2),
		z
	)
	house:setEntryPosition(entry)

	-- ensureGroundOrWall uses sharedHouse; assign before stamping floors/walls.
	sharedHouse = house

	for ly = 0, outer - 1 do
		for lx = 0, outer - 1 do
			house:addTile(Position(origin.x + lx, origin.y + ly, z))
		end
	end

	for ly = 0, floor - 1 do
		for lx = 0, floor - 1 do
			ensureGroundOrWall(Position(origin.x + 1 + lx, origin.y + 1 + ly, z), floorId)
		end
	end

	local maxOuter = outer - 1
	for ly = 0, outer - 1 do
		for lx = 0, outer - 1 do
			local id = wallId(lx, ly, outer)
			if id then
				local pos = Position(origin.x + lx, origin.y + ly, z)
				local skipFloor = (lx == maxOuter and ly == 0) or (lx == 0 and ly == maxOuter)
				if not skipFloor then
					ensureGroundOrWall(pos, floorId)
				else
					house:addTile(pos)
					local tile = Tile(pos)
					local ground = tile and tile:getGround() or nil
					if ground and ground:getId() == floorId then
						ground:remove()
					end
				end
				house:addTile(pos)
				local tile = Tile(pos)
				if tile then
					local items = tile:getItems()
					local hasWall = false
					if items then
						for _, it in ipairs(items) do
							if it:getId() == id then
								hasWall = true
								break
							end
						end
					end
					if not hasWall then
						Game.createItem(id, 1, pos)
					end
				end
			end
		end
	end

	sharedZone = Zone(PlayerHomeConfig.ZONE_NAME)
	local toPos = Position(origin.x + outer - 1, origin.y + outer - 1, z)
	sharedZone:addArea(origin, toPos)

	local floorOrigin = Position(origin.x + 1, origin.y + 1, z)
	local lockerLayout = PlayerHomeConfig.lockerLayout and PlayerHomeConfig.lockerLayout() or {}
	for _, spec in ipairs(lockerLayout) do
		if spec.id then
			local pos = Position(floorOrigin.x + (spec.dx or 0), floorOrigin.y + (spec.dy or 0), floorOrigin.z)
			ensureTemplateItemAt(pos, spec.id)
		end
	end

	templateReady = true
	return sharedHouse
end

function PlayerHomeInstance.resetSlots()
	templateReady = false
	sharedHouse = nil
	sharedZone = nil
end

--- Session descriptor for one private instance overlay on the shared footprint.
function PlayerHomeInstance.build(instanceId)
	PlayerHomeInstance.ensureTemplate()
	local origin = sharedOrigin()
	local floor = PlayerHomeConfig.FLOOR_SIZE
	local outer = PlayerHomeConfig.OUTER_SIZE
	local z = origin.z

	local entry = Position(
		origin.x + 1 + math.floor(floor / 2),
		origin.y + 1 + math.floor(floor / 2),
		z
	)
	local floorOrigin = Position(origin.x + 1, origin.y + 1, z)
	local hirelingPos = Position(
		floorOrigin.x + (PlayerHomeConfig.HIRELING_FLOOR_DX or 0),
		floorOrigin.y + (PlayerHomeConfig.HIRELING_FLOOR_DY or math.max(0, floor - 3)),
		z
	)

	local lockerDx = PlayerHomeConfig.LOCKER_CORNER_DX or 6
	local lockerDy = PlayerHomeConfig.LOCKER_CORNER_DY or 6
	local lockerSe = Position(floorOrigin.x + lockerDx, floorOrigin.y + lockerDy, z)

	local instance = {
		origin = origin,
		width = outer,
		height = outer,
		floorSize = floor,
		zone = sharedZone,
		zoneName = PlayerHomeConfig.ZONE_NAME,
		entry = entry,
		floorOrigin = floorOrigin,
		hirelingPos = hirelingPos,
		hirelingNpcId = nil,
		house = sharedHouse,
		instanceId = instanceId,
		channel = nil,
		lockerPos = lockerSe,
		lockerCorner = {
			nw = Position(lockerSe.x - 1, lockerSe.y - 1, lockerSe.z),
			ne = Position(lockerSe.x, lockerSe.y - 1, lockerSe.z),
			sw = Position(lockerSe.x - 1, lockerSe.y, lockerSe.z),
			se = lockerSe,
		},
	}

	for _, spec in ipairs(PlayerHomeConfig.FURNITURE or {}) do
		if spec.key then
			instance[spec.key] = Position(floorOrigin.x + (spec.dx or 0), floorOrigin.y + (spec.dy or 0), z)
		end
	end

	if Game.setInstancePrivateFence then
		Game.setInstancePrivateFence(instanceId, nil, {
			x = origin.x,
			y = origin.y,
			w = outer,
			h = outer,
		}, { z })
	end

	return instance
end

--- Mark furniture as store-bound (same as store inbox): owned + STORE attr.
function PlayerHome.bindStoreItem(item, player)
	if not item or not player then
		return item
	end
	if item.setOwner then
		item:setOwner(player)
	end
	if ITEM_ATTRIBUTE_STORE and item.setAttribute then
		local stamp = systemTime and systemTime() or os.time()
		item:setAttribute(ITEM_ATTRIBUTE_STORE, stamp)
	end
	return item
end

--- Place a private copy of starter furniture for this home instance (not instance 0).
function PlayerHomeInstance.stampStarterFurniture(instance, player)
	if not instance or not instance.floorOrigin or not instance.instanceId then
		return 0
	end
	local layout = PlayerHomeConfig.starterLayout and PlayerHomeConfig.starterLayout() or {}
	local fo = instance.floorOrigin
	local placed = 0
	for _, spec in ipairs(layout) do
		if spec.id then
			local pos = Position(fo.x + (spec.dx or 0), fo.y + (spec.dy or 0), fo.z)
			if instance.house and instance.house.addTile then
				instance.house:addTile(pos)
			elseif not Tile(pos) then
				Game.createTile(pos, true)
			end
			local item = Game.createItem(spec.id, 1)
			if item then
				if item.setInstanceId then
					item:setInstanceId(instance.instanceId)
				end
				item:moveTo(pos)
				if item.setInstanceId then
					item:setInstanceId(instance.instanceId)
				end
				if player then
					PlayerHome.bindStoreItem(item, player)
				end
				placed = placed + 1
			end
		end
	end
	return placed
end

function PlayerHomeInstance.bindFurnitureOwnership(instance, player)
	if not instance or not instance.floorOrigin or not player or not instance.instanceId then
		return
	end
	local fo = instance.floorOrigin
	local size = instance.floorSize or PlayerHomeConfig.FLOOR_SIZE
	for dy = 0, size - 1 do
		for dx = 0, size - 1 do
			local tile = Tile(Position(fo.x + dx, fo.y + dy, fo.z))
			local items = tileItemsForInstance(tile, instance.instanceId)
			if items then
				for _, item in ipairs(items) do
					if item and PlayerHomeConfig.isFurnitureId and PlayerHomeConfig.isFurnitureId(item:getId()) then
						PlayerHome.bindStoreItem(item, player)
					end
				end
			end
		end
	end
end

function PlayerHomeInstance.spawnHireling(instance)
	if not instance or not instance.hirelingPos then
		return nil
	end
	if instance.hirelingNpcId then
		local existing = Npc(instance.hirelingNpcId)
		if existing then
			return existing
		end
		instance.hirelingNpcId = nil
	end

	local npcName = PlayerHomeConfig.HIRELING_NPC or "Remote Hireling Trader"
	local pos = instance.hirelingPos
	if sharedHouse then
		sharedHouse:addTile(pos)
	end
	local npc = Game.createNpc(npcName, pos, false, false, instance.instanceId)
	if not npc then
		logger.warn("[PlayerHome] failed to spawn hireling NPC at {},{},{}", pos.x, pos.y, pos.z)
		return nil
	end
	if npc.setMasterPos then
		npc:setMasterPos(pos)
	end
	instance.hirelingNpcId = npc:getId()
	return npc
end

local function removeCreaturesOnTile(tile, instanceId)
	if not tile then
		return
	end
	local creatures = tile.getCreatures and tile:getCreatures() or nil
	if creatures then
		for i = #creatures, 1, -1 do
			local c = creatures[i]
			if c and not c:isPlayer() and c.getInstanceId and c:getInstanceId() == instanceId then
				c:remove()
			end
		end
		return
	end
	local top = tile.getTopCreature and tile:getTopCreature() or nil
	if top and not top:isPlayer() and top.getInstanceId and top:getInstanceId() == instanceId then
		top:remove()
	end
end

function PlayerHomeInstance.contains(instance, pos)
	if not instance or not pos then
		return false
	end
	if instance.zone and instance.zone.isInZone then
		return instance.zone:isInZone(pos)
	end
	local o = instance.origin
	if not o then
		return false
	end
	local w = instance.width or PlayerHomeConfig.OUTER_SIZE
	local h = instance.height or PlayerHomeConfig.OUTER_SIZE
	return pos.z == o.z
		and pos.x >= o.x
		and pos.x < o.x + w
		and pos.y >= o.y
		and pos.y < o.y + h
end

function PlayerHomeInstance.isHomeTile(tile)
	if not tile then
		return false
	end
	local pos = tile:getPosition()
	if not pos then
		return false
	end
	if PlayerHomeManager and PlayerHomeManager.isPositionInAnyHome then
		return PlayerHomeManager.isPositionInAnyHome(pos)
	end
	local o = sharedOrigin()
	local outer = PlayerHomeConfig.OUTER_SIZE
	return pos.z == o.z
		and pos.x >= o.x
		and pos.x < o.x + outer
		and pos.y >= o.y
		and pos.y < o.y + outer
end

function PlayerHome.isHouseCapableTile(tile)
	if not tile then
		return false
	end
	if tile:getHouse() then
		return true
	end
	return PlayerHomeInstance.isHomeTile(tile)
end

function PlayerHomeInstance.teardown(instance)
	if not instance or not instance.instanceId then
		return
	end
	local instanceId = instance.instanceId

	if instance.hirelingNpcId then
		local npc = Npc(instance.hirelingNpcId)
		if npc then
			npc:remove()
		end
		instance.hirelingNpcId = nil
	end

	if instance.house and instance.house.clearInstanceOwner then
		instance.house:clearInstanceOwner(instanceId)
	end

	if instance.zone then
		local positions = instance.zone:getPositions()
		if positions then
			for _, pos in ipairs(positions) do
				local tile = Tile(pos)
				if tile then
					removeCreaturesOnTile(tile, instanceId)
					local items = tile:getItems()
					if items then
						for i = #items, 1, -1 do
							local it = items[i]
							if it and itemMatchesInstance(it, instanceId) then
								it:remove()
							end
						end
					end
				end
			end
		end
	end
	if Game.clearInstancePrivateFence then
		Game.clearInstancePrivateFence(instanceId)
	end
	instance.instanceId = nil
end
