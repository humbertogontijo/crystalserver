-- Lobby room: stamped variant footprints (world template, see 03_variants.lua) + one reserved
-- engine channel of the lobby place ("lobby:0:<channel>") per live lobby, fenced on the
-- variant matching the lobby's expedition. Built when the first member enters, torn down
-- when empty. Never saved.
LobbyInstance = LobbyInstance or {}

local templateReady = false
-- lobbyId -> room { lobbyId, instanceId, channel, variantKey, origin, floorOrigin, entry, slots, ... }
local roomsByLobbyId = {}
-- engine instance key -> lobbyId
local lobbyIdByInstance = {}

--- Stamp every room variant on instance 0 once (floor, walls, PZ flags, fixtures, lever rooms).
function LobbyInstance.ensureTemplate()
	if templateReady then
		return true
	end
	LobbyVariants.stampAll()
	templateReady = true
	logger.info("[Lobby] room template stamped at {},{},{}", LobbyConfig.ROOM_BASE_X, LobbyConfig.ROOM_BASE_Y, LobbyConfig.ROOM_Z)
	return true
end

--- Any stamped lobby room tile (walls included), whichever variant.
function LobbyInstance.isLobbyPosition(pos)
	return LobbyVariants.atPosition(pos) ~= nil
end

local function inRoomRect(room, pos)
	local o = room.origin
	return pos.z == o.z and pos.x >= o.x and pos.x < o.x + room.width and pos.y >= o.y and pos.y < o.y + room.height
end

function LobbyInstance.getRoom(record)
	return record and roomsByLobbyId[record.id] or nil
end

function LobbyInstance.roomByInstanceId(instanceId)
	local lobbyId = lobbyIdByInstance[Instance.normalize(instanceId)]
	return lobbyId and roomsByLobbyId[lobbyId] or nil
end

--- Room the player is standing in (by engine instance id and the room's current variant), if any.
function LobbyInstance.roomForPlayer(player)
	if not player then
		return nil
	end
	local room = LobbyInstance.roomByInstanceId(player:getInstanceId())
	if room and inRoomRect(room, player:getPosition()) then
		return room
	end
	return nil
end

function LobbyInstance.isInRoom(player, record)
	local room = LobbyInstance.roomForPlayer(player)
	return room ~= nil and record ~= nil and room.lobbyId == record.id
end

--- Point the room at `variant` (geometry, slots, fixtures) and fence the instance on it.
local function placeRoom(room, variant)
	local fo = variant.floorOrigin
	room.variantKey = variant.key
	room.origin = variant.origin
	room.floorOrigin = fo
	room.width, room.height = LobbyVariants.outerSize()
	room.slots = variant.slots
	room.lever = variant.lever
	room.entry = Position(fo.x + LobbyConfig.SPAWN_OFFSETS[1][1], fo.y + LobbyConfig.SPAWN_OFFSETS[1][2], fo.z)
	for _, spec in ipairs(LobbyConfig.fixtureLayout()) do
		if spec.key then
			room[spec.key] = Position(fo.x + spec.dx, fo.y + spec.dy, fo.z)
		end
	end
	local o = room.origin
	-- Replaces the previous fence of this instance.
	Game.setInstancePrivateFence(room.instanceId, nil, { x = o.x, y = o.y, w = room.width, h = room.height }, { o.z })
end

--- Allocate the private overlay for a lobby (idempotent).
function LobbyInstance.ensureRoom(record)
	if not record then
		return nil, "No lobby."
	end
	local existing = roomsByLobbyId[record.id]
	if existing then
		LobbyInstance.applyVariant(record)
		return existing
	end
	LobbyInstance.ensureTemplate()
	local engineId = ExpeditionInstance and ExpeditionInstance.allocate and ExpeditionInstance.allocate("lobby", 0, record.id) or nil
	if engineId == nil then
		return nil, "No lobby rooms available right now."
	end
	local room = {
		lobbyId = record.id,
		instanceId = engineId,
		channel = Instance.channel(engineId),
	}
	placeRoom(room, LobbyVariants.get(LobbyVariants.keyForRecord(record)))
	if InstanceWorld and InstanceWorld.rememberFloors then
		InstanceWorld.rememberFloors(engineId, { [LobbyConfig.ROOM_Z] = true })
	end
	roomsByLobbyId[record.id] = room
	lobbyIdByInstance[engineId] = record.id
	logger.info("[Lobby] room built for lobby #{} instance={} variant={}", record.id, engineId, room.variantKey)
	return room
end

local function occupants(room)
	return room and Game.getInstanceMembers(room.instanceId) or {}
end
LobbyInstance.occupants = occupants

--- Interior tile a creature can stand on (ground, nothing solid); fixtures and cloned decor block.
local function walkable(room, x, y)
	local fo = room.floorOrigin
	if x < fo.x or y < fo.y or x >= fo.x + LobbyConfig.ROOM_FLOOR_W or y >= fo.y + LobbyConfig.ROOM_FLOOR_H then
		return false
	end
	local tile = Tile(Position(x, y, fo.z))
	if not tile or not tile:getGround() then
		return false
	end
	return not (
		tile:hasProperty(CONST_PROP_BLOCKSOLID)
		or tile:hasProperty(CONST_PROP_IMMOVABLEBLOCKSOLID)
		or tile:hasProperty(CONST_PROP_BLOCKPATH)
	)
end

local function takenTiles(room, except)
	local taken = {}
	for _, p in ipairs(occupants(room)) do
		if p ~= except then
			local pos = p:getPosition()
			taken[pos.x .. ":" .. pos.y] = true
		end
	end
	return taken
end

--- Nearest free walkable interior tile to (x, y), ring by ring.
local function nearestFree(room, x, y, taken)
	local maxR = math.max(LobbyConfig.ROOM_FLOOR_W, LobbyConfig.ROOM_FLOOR_H)
	for r = 0, maxR do
		for dy = -r, r do
			for dx = -r, r do
				if math.max(math.abs(dx), math.abs(dy)) == r then
					local tx, ty = x + dx, y + dy
					if not taken[tx .. ":" .. ty] and walkable(room, tx, ty) then
						return Position(tx, ty, room.floorOrigin.z)
					end
				end
			end
		end
	end
	return nil
end

--- Free tile for the next arrival (spreads members around the room center).
function LobbyInstance.spawnPosition(room, index)
	local fo = room.floorOrigin
	local offsets = LobbyConfig.SPAWN_OFFSETS
	if index then
		local o = offsets[((index - 1) % #offsets) + 1]
		return Position(fo.x + o[1], fo.y + o[2], fo.z)
	end
	local taken = takenTiles(room)
	for _, o in ipairs(offsets) do
		local x, y = fo.x + o[1], fo.y + o[2]
		if not taken[x .. ":" .. y] and walkable(room, x, y) then
			return Position(x, y, fo.z)
		end
	end
	return nearestFree(room, room.entry.x, room.entry.y, taken) or room.entry
end

local function memberIndex(record, guid)
	for i, m in ipairs(record and record.members or {}) do
		if m.guid == guid then
			return i
		end
	end
	return nil
end

--- Lever slot of `player` in a lever-boss room (member order), nil when none or taken.
local function slotPosition(room, record, player, taken)
	if not room.slots then
		return nil
	end
	local index = memberIndex(record, player:getGuid())
	local slot = index and room.slots[index]
	if not slot then
		return nil
	end
	local fo = room.floorOrigin
	local x, y = fo.x + slot[1], fo.y + slot[2]
	if taken[x .. ":" .. y] or not walkable(room, x, y) then
		return nil
	end
	return Position(x, y, fo.z)
end

--- Arrival tile for `player`: their lever slot in lever-boss rooms, else a spawn tile.
function LobbyInstance.arrivalPosition(room, record, player)
	return slotPosition(room, record, player, takenTiles(room, player)) or LobbyInstance.spawnPosition(room)
end

local function moveWithin(room, creature, dest)
	local ok
	if InstanceWorld and InstanceWorld.enterInstance then
		ok = InstanceWorld.enterInstance(creature, room.instanceId, dest)
	else
		ok = creature:teleportTo(dest, false, room.instanceId)
	end
	if ok then
		Game.runInInstance(room.instanceId, function()
			dest:sendMagicEffect(CONST_ME_TELEPORT)
		end)
	end
	return ok
end

--- Lever-boss room: move the members inside onto their slots (member order).
function LobbyInstance.arrange(record)
	local room = record and roomsByLobbyId[record.id]
	if not room or not room.slots then
		return
	end
	local fo = room.floorOrigin
	for _, p in ipairs(occupants(room)) do
		local index = memberIndex(record, p:getGuid())
		local slot = index and room.slots[index]
		local pos = p:getPosition()
		if slot and (pos.x ~= fo.x + slot[1] or pos.y ~= fo.y + slot[2]) then
			local dest = slotPosition(room, record, p, takenTiles(room, p))
			if dest then
				moveWithin(room, p, dest)
			end
		end
	end
end

local function removeInstanceThings(room)
	local o = room.origin
	for ly = 0, room.height - 1 do
		for lx = 0, room.width - 1 do
			local tile = Tile(Position(o.x + lx, o.y + ly, o.z))
			if tile then
				for _, c in ipairs(tile:getCreatures() or {}) do
					if not c:isPlayer() and c:getInstanceId() == room.instanceId then
						c:remove()
					end
				end
				local items = tile:getItems() or {}
				for i = #items, 1, -1 do
					local it = items[i]
					if it and it:getInstanceId() == room.instanceId then
						it:remove()
					end
				end
			end
		end
	end
end

--- Move a live room to the variant of the lobby's expedition: re-fence, then carry everyone
--- inside to the same floor offsets (lever-boss rooms: onto the slots in member order).
--- Returns true when the room switched.
function LobbyInstance.applyVariant(record)
	local room = record and roomsByLobbyId[record.id]
	if not room then
		return false
	end
	local variant = LobbyVariants.get(LobbyVariants.keyForRecord(record))
	if not variant or variant.key == room.variantKey then
		return false
	end
	local from = room.floorOrigin
	local moves = {}
	for _, p in ipairs(occupants(room)) do
		local pos = p:getPosition()
		if inRoomRect(room, pos) then
			moves[#moves + 1] = { creature = p, dx = pos.x - from.x, dy = pos.y - from.y }
			for _, summon in ipairs(p:getSummons() or {}) do
				local spos = summon:getPosition()
				if inRoomRect(room, spos) then
					moves[#moves + 1] = { creature = summon, dx = spos.x - from.x, dy = spos.y - from.y, summon = true }
				end
			end
		end
	end
	local previous = { origin = room.origin, width = room.width, height = room.height, instanceId = room.instanceId }
	placeRoom(room, variant)

	local to = room.floorOrigin
	local taken = {}
	local placed = {}
	-- Slots first so offset moves cannot take a member's slot.
	for i, move in ipairs(moves) do
		if not move.summon then
			local dest = slotPosition(room, record, move.creature, taken)
			if dest then
				taken[dest.x .. ":" .. dest.y] = true
				placed[i] = dest
			end
		end
	end
	for i, move in ipairs(moves) do
		local dest = placed[i] or nearestFree(room, to.x + move.dx, to.y + move.dy, taken) or room.entry
		taken[dest.x .. ":" .. dest.y] = true
		moveWithin(room, move.creature, dest)
		if not move.summon and InstanceWorld and InstanceWorld.sendBounds then
			InstanceWorld.sendBounds(move.creature, true)
		end
	end
	-- Instance leftovers (lever / door forks) of the room just left; everyone moved first.
	removeInstanceThings(previous)
	logger.info("[Lobby] lobby #{} moved to room variant {}", record.id, variant.key)
	return true
end

--- Tear down the overlay once nobody is inside. Safe to call any time.
function LobbyInstance.teardownIfEmpty(lobbyId)
	local room = roomsByLobbyId[tonumber(lobbyId) or 0]
	if not room or #occupants(room) > 0 then
		return false
	end
	removeInstanceThings(room)
	Game.releaseInstance(room.instanceId)
	return true
end

--- Rooms are forgotten when their channel is released, whoever releases it.
IdleEvents.on("instance.released", function(instanceKey)
	local key = Instance.normalize(instanceKey)
	local lobbyId = lobbyIdByInstance[key]
	if not lobbyId then
		return
	end
	lobbyIdByInstance[key] = nil
	roomsByLobbyId[lobbyId] = nil
	logger.info("[Lobby] room torn down for lobby #{}", lobbyId)
end, "LobbyInstance")

--- Re-check after a hop resolves (teleports land on the next tick).
function LobbyInstance.scheduleTeardownCheck(lobbyId)
	addEvent(LobbyInstance.teardownIfEmpty, 200, lobbyId)
end

local function saveReturnPos(player)
	local pos = player:getPosition()
	if LobbyInstance.isLobbyPosition(pos) then
		return
	end
	if ExpeditionManager and ExpeditionManager.getSessionByPlayer and ExpeditionManager.getSessionByPlayer(player) then
		return
	end
	-- Hunt / raid tiles are never a place to come back to.
	if Instance.isPrivate(player:getInstanceId()) then
		return
	end
	player:setStorageValue(LobbyConfig.STORAGE_RETURN_X, pos.x)
	player:setStorageValue(LobbyConfig.STORAGE_RETURN_Y, pos.y)
	player:setStorageValue(LobbyConfig.STORAGE_RETURN_Z, pos.z)
end

function LobbyInstance.loadReturnPos(player)
	local x = player:getStorageValue(LobbyConfig.STORAGE_RETURN_X)
	local y = player:getStorageValue(LobbyConfig.STORAGE_RETURN_Y)
	local z = player:getStorageValue(LobbyConfig.STORAGE_RETURN_Z)
	if x and y and z and x > 0 and y > 0 and z >= 0 then
		local pos = Position(x, y, z)
		if not LobbyInstance.isLobbyPosition(pos) then
			return pos
		end
	end
	local town = player:getTown()
	if town then
		return town:getTemplePosition()
	end
	return Position(32369, 32241, 7)
end

--- Move a creature into the lobby room now (no channel). opts.position overrides the tile.
function LobbyInstance.enterNow(creature, record, opts)
	opts = opts or {}
	local room, err = LobbyInstance.ensureRoom(record)
	if not room then
		return false, err
	end
	local player = creature:getPlayer() or creature
	local alreadyIn = LobbyInstance.isInRoom(player, record)
	if alreadyIn and not opts.position then
		return true
	end
	if player and player:isPlayer() and not alreadyIn then
		saveReturnPos(player)
	end
	local dest = opts.position or LobbyInstance.arrivalPosition(room, record, player)
	local previousLobbyRoom = LobbyInstance.roomForPlayer(player)
	local ok = false
	if InstanceWorld and InstanceWorld.enterInstance then
		ok = InstanceWorld.enterInstance(creature, room.instanceId, dest) and true or false
	else
		ok = creature:teleportTo(dest, false, room.instanceId) and true or false
	end
	if not ok then
		LobbyInstance.scheduleTeardownCheck(record.id)
		return false, "Failed to enter the lobby room."
	end
	if previousLobbyRoom and previousLobbyRoom.lobbyId ~= record.id then
		LobbyInstance.scheduleTeardownCheck(previousLobbyRoom.lobbyId)
	end
	if InstanceTeleport and InstanceTeleport.sendArrivalEffect then
		InstanceTeleport.sendArrivalEffect(creature, InstanceTeleport.KIND_LOBBY)
	end
	if InstanceWorld and InstanceWorld.sendBounds then
		InstanceWorld.sendBounds(player, true)
	end
	if LobbyStart and LobbyStart.onEnteredRoom then
		-- Deferred: the start flow may launch the expedition from here.
		local pid, lobbyId = player:getId(), record.id
		addEvent(function()
			local p = Player(pid)
			local live = LobbyStore.get(lobbyId)
			if p and live and LobbyInstance.isInRoom(p, live) then
				LobbyStart.onEnteredRoom(p, live)
			end
		end, 0)
	end
	if LobbyProtocol and LobbyProtocol.broadcast then
		LobbyProtocol.broadcast(LobbyStore.get(record.id))
	end
	return true
end

--- Leave the lobby room for the open world (return tile or `dest`).
function LobbyInstance.leaveNow(player, dest)
	local room = LobbyInstance.roomForPlayer(player)
	dest = dest or LobbyInstance.loadReturnPos(player)
	local ok
	if InstanceWorld and InstanceWorld.exitToOpenWorld then
		ok = InstanceWorld.exitToOpenWorld(player, dest) and true or false
	else
		ok = player:teleportTo(dest) and true or false
	end
	if room then
		LobbyInstance.scheduleTeardownCheck(room.lobbyId)
	end
	if not ok then
		return false, "Failed to leave the lobby room."
	end
	if InstanceTeleport and InstanceTeleport.sendArrivalEffect then
		InstanceTeleport.sendArrivalEffect(player, InstanceTeleport.KIND_HOMETOWN)
	end
	if InstanceWorld and InstanceWorld.sendBounds then
		InstanceWorld.sendBounds(player, true)
	end
	if LobbyProtocol and LobbyProtocol.broadcast then
		LobbyProtocol.broadcast(LobbyStore.getForPlayer(player))
	end
	return true
end

--- Identity for topbar / instanceBounds when standing in a lobby room.
function LobbyInstance.describe(player)
	local room = LobbyInstance.roomForPlayer(player)
	if not room then
		return nil
	end
	return {
		subareaId = Instance.subareaId(room.instanceId),
		kind = "lobby",
		key = room.instanceId,
		channel = room.channel,
		bounds = { x = room.origin.x, y = room.origin.y, w = room.width, h = room.height },
	}
end

--- Logout inside a room: remember it so login restores into the lobby.
function LobbyInstance.onLogout(player)
	local room = LobbyInstance.roomForPlayer(player)
	if LobbyServices and LobbyServices.onLeave then
		LobbyServices.onLeave(player)
	end
	if not room then
		return
	end
	if not (Alts and Alts.isCompanion and Alts.isCompanion(player)) then
		player:kv():set(LobbyConfig.KV_INSIDE_LOBBY, tostring(room.lobbyId))
	end
	LobbyInstance.scheduleTeardownCheck(room.lobbyId)
end

--- Login on a lobby tile: back into the player's lobby, else their personal lobby, else temple.
--- Returns true when the login position was handled here.
function LobbyInstance.restoreOnLogin(player)
	if not player then
		return false
	end
	local pos = player:getPosition()
	local marked = player:kv():get(LobbyConfig.KV_INSIDE_LOBBY)
	if not LobbyInstance.isLobbyPosition(pos) then
		if marked then
			player:kv():remove(LobbyConfig.KV_INSIDE_LOBBY)
		end
		return false
	end
	player:kv():remove(LobbyConfig.KV_INSIDE_LOBBY)
	-- Headless deploys place straight onto a live room id.
	local current = LobbyInstance.roomByInstanceId(player:getInstanceId())
	if current then
		-- The lobby switched room variant while this player was offline.
		if not LobbyInstance.roomForPlayer(player) then
			local record = LobbyStore.get(current.lobbyId)
			local dest = record and LobbyInstance.arrivalPosition(current, record, player) or current.entry
			if InstanceWorld and InstanceWorld.enterInstance then
				InstanceWorld.enterInstance(player, current.instanceId, dest)
			else
				player:teleportTo(dest, false, current.instanceId)
			end
		end
		return true
	end
	local record = LobbyManager and LobbyManager.ensureForPlayer and LobbyManager.ensureForPlayer(player) or nil
	if record and LobbyInstance.enterNow(player, record, {}) then
		return true
	end
	local town = player:getTown()
	local temple = town and town:getTemplePosition() or Position(32369, 32241, 7)
	if InstanceWorld and InstanceWorld.exitToOpenWorld then
		InstanceWorld.exitToOpenWorld(player, temple)
	else
		player:teleportTo(temple)
	end
	return true
end

function LobbyInstance.onStartup()
	roomsByLobbyId = {}
	lobbyIdByInstance = {}
	templateReady = false
	LobbyInstance.ensureTemplate()
end
