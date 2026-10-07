-- Lobby room: shared stamped footprint (world template) + one reserved engine channel of the
-- lobby place ("lobby:0:<channel>") per live lobby. Built when the first member enters, torn
-- down when empty. Never saved.
LobbyInstance = LobbyInstance or {}

local templateReady = false
-- lobbyId -> room { lobbyId, instanceId, channel, origin, floorOrigin, entry, ... }
local roomsByLobbyId = {}
-- engine instance key -> lobbyId
local lobbyIdByInstance = {}

local function outerW()
	return LobbyConfig.ROOM_FLOOR_W + 2
end

local function outerH()
	return LobbyConfig.ROOM_FLOOR_H + 2
end

local function origin()
	return Position(LobbyConfig.ROOM_BASE_X, LobbyConfig.ROOM_BASE_Y, LobbyConfig.ROOM_Z)
end

local function floorOrigin()
	return Position(LobbyConfig.ROOM_BASE_X + 1, LobbyConfig.ROOM_BASE_Y + 1, LobbyConfig.ROOM_Z)
end

local function wallId(lx, ly)
	local maxX, maxY = outerW() - 1, outerH() - 1
	local onN, onS = ly == 0, ly == maxY
	local onW, onE = lx == 0, lx == maxX
	if onN and onW then
		return LobbyConfig.ROOM_WALL_TL
	elseif onN and onE then
		return LobbyConfig.ROOM_WALL_TR
	elseif onS and onW then
		return LobbyConfig.ROOM_WALL_BL
	elseif onS and onE then
		return LobbyConfig.ROOM_WALL_BR
	elseif onN or onS then
		return LobbyConfig.ROOM_WALL_H
	elseif onW or onE then
		return LobbyConfig.ROOM_WALL_V
	end
	return nil
end

local function ensureTile(pos)
	return Tile(pos) or Game.createTile(pos, false)
end

local function ensureGround(pos, itemId)
	local tile = ensureTile(pos)
	if not tile then
		return nil
	end
	local ground = tile:getGround()
	if not ground then
		Game.createItem(itemId, 1, pos)
	elseif ground:getId() ~= itemId then
		ground:transform(itemId)
	end
	return Tile(pos)
end

local function ensureItem(pos, itemId, actionId)
	local tile = ensureTile(pos)
	if not tile then
		return nil
	end
	local item = tile:getItemById(itemId)
	if not item then
		item = Game.createItem(itemId, 1, pos)
	end
	if item and actionId then
		item:setActionId(actionId)
	end
	return item
end

--- Stamp the shared room on instance 0 once (floor, walls, PZ flags, fixtures).
function LobbyInstance.ensureTemplate()
	if templateReady then
		return true
	end
	local o = origin()
	local fo = floorOrigin()
	local floorId = LobbyConfig.ROOM_FLOOR_ID

	for ly = 0, LobbyConfig.ROOM_FLOOR_H - 1 do
		for lx = 0, LobbyConfig.ROOM_FLOOR_W - 1 do
			local tile = ensureGround(Position(fo.x + lx, fo.y + ly, fo.z), floorId)
			if tile and tile.setFlag then
				tile:setFlag(TILESTATE_PROTECTIONZONE)
			end
		end
	end

	local maxX, maxY = outerW() - 1, outerH() - 1
	for ly = 0, maxY do
		for lx = 0, maxX do
			local id = wallId(lx, ly)
			if id then
				local pos = Position(o.x + lx, o.y + ly, o.z)
				-- The NE / SW corner sprites are drawn without floor beneath them.
				local bare = (lx == maxX and ly == 0) or (lx == 0 and ly == maxY)
				if bare then
					ensureTile(pos)
				else
					ensureGround(pos, floorId)
				end
				ensureItem(pos, id)
			end
		end
	end

	for _, spec in ipairs(LobbyConfig.fixtureLayout()) do
		ensureItem(Position(fo.x + spec.dx, fo.y + spec.dy, fo.z), spec.id, LobbyConfig.FIXTURE_ACTION_ID)
	end

	templateReady = true
	logger.info("[Lobby] room template stamped at {},{},{}", o.x, o.y, o.z)
	return true
end

function LobbyInstance.isLobbyPosition(pos)
	if not pos then
		return false
	end
	local o = origin()
	return pos.z == o.z and pos.x >= o.x and pos.x < o.x + outerW() and pos.y >= o.y and pos.y < o.y + outerH()
end

function LobbyInstance.getRoom(record)
	return record and roomsByLobbyId[record.id] or nil
end

function LobbyInstance.roomByInstanceId(instanceId)
	local lobbyId = lobbyIdByInstance[Instance.normalize(instanceId)]
	return lobbyId and roomsByLobbyId[lobbyId] or nil
end

--- Room the player is standing in (by engine instance id), if any.
function LobbyInstance.roomForPlayer(player)
	if not player or not player.getInstanceId then
		return nil
	end
	local room = LobbyInstance.roomByInstanceId(player:getInstanceId())
	if room and LobbyInstance.isLobbyPosition(player:getPosition()) then
		return room
	end
	return nil
end

function LobbyInstance.isInRoom(player, record)
	local room = LobbyInstance.roomForPlayer(player)
	return room ~= nil and record ~= nil and room.lobbyId == record.id
end

--- Allocate the private overlay for a lobby (idempotent).
function LobbyInstance.ensureRoom(record)
	if not record then
		return nil, "No lobby."
	end
	local existing = roomsByLobbyId[record.id]
	if existing then
		return existing
	end
	LobbyInstance.ensureTemplate()
	local engineId = ExpeditionInstance and ExpeditionInstance.allocate and ExpeditionInstance.allocate("lobby", 0, record.id) or nil
	if engineId == nil then
		return nil, "No lobby rooms available right now."
	end
	local o = origin()
	local fo = floorOrigin()
	local room = {
		lobbyId = record.id,
		instanceId = engineId,
		channel = Instance.channel(engineId),
		origin = o,
		floorOrigin = fo,
		width = outerW(),
		height = outerH(),
		entry = Position(fo.x + LobbyConfig.SPAWN_OFFSETS[1][1], fo.y + LobbyConfig.SPAWN_OFFSETS[1][2], fo.z),
	}
	for _, spec in ipairs(LobbyConfig.fixtureLayout()) do
		if spec.key then
			room[spec.key] = Position(fo.x + spec.dx, fo.y + spec.dy, fo.z)
		end
	end
	Game.setInstancePrivateFence(engineId, nil, { x = o.x, y = o.y, w = room.width, h = room.height }, { o.z })
	if InstanceWorld and InstanceWorld.rememberFloors then
		InstanceWorld.rememberFloors(engineId, { [o.z] = true })
	end
	roomsByLobbyId[record.id] = room
	lobbyIdByInstance[engineId] = record.id
	logger.info("[Lobby] room built for lobby #{} instance={}", record.id, engineId)
	return room
end

local function occupants(room)
	local list = {}
	if not room then
		return list
	end
	for _, p in ipairs(Game.getPlayers()) do
		if p.getInstanceId and p:getInstanceId() == room.instanceId then
			list[#list + 1] = p
		end
	end
	return list
end
LobbyInstance.occupants = occupants

--- Free tile for the next arrival (spreads members around the room center).
function LobbyInstance.spawnPosition(room, index)
	local fo = room.floorOrigin
	local taken = {}
	for _, p in ipairs(occupants(room)) do
		local pos = p:getPosition()
		taken[pos.x .. ":" .. pos.y] = true
	end
	local offsets = LobbyConfig.SPAWN_OFFSETS
	if index then
		local o = offsets[((index - 1) % #offsets) + 1]
		return Position(fo.x + o[1], fo.y + o[2], fo.z)
	end
	for _, o in ipairs(offsets) do
		local x, y = fo.x + o[1], fo.y + o[2]
		if not taken[x .. ":" .. y] then
			return Position(x, y, fo.z)
		end
	end
	return room.entry
end

local function removeInstanceThings(room)
	local o = room.origin
	for ly = 0, room.height - 1 do
		for lx = 0, room.width - 1 do
			local tile = Tile(Position(o.x + lx, o.y + ly, o.z))
			if tile then
				for _, c in ipairs(tile:getCreatures() or {}) do
					if not c:isPlayer() and c.getInstanceId and c:getInstanceId() == room.instanceId then
						c:remove()
					end
				end
				local items = tile:getItems() or {}
				for i = #items, 1, -1 do
					local it = items[i]
					if it and it.getInstanceId and it:getInstanceId() == room.instanceId then
						it:remove()
					end
				end
			end
		end
	end
end

--- Tear down the overlay once nobody is inside. Safe to call any time.
function LobbyInstance.teardownIfEmpty(lobbyId)
	local room = roomsByLobbyId[tonumber(lobbyId) or 0]
	if not room or #occupants(room) > 0 then
		return false
	end
	removeInstanceThings(room)
	if ExpeditionInstance and ExpeditionInstance.free then
		ExpeditionInstance.free(room.instanceId)
	end
	lobbyIdByInstance[room.instanceId] = nil
	roomsByLobbyId[room.lobbyId] = nil
	logger.info("[Lobby] room torn down for lobby #{}", room.lobbyId)
	return true
end

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
	local player = creature.getPlayer and creature:getPlayer() or creature
	local alreadyIn = LobbyInstance.isInRoom(player, record)
	if alreadyIn and not opts.position then
		return true
	end
	if player and player.isPlayer and player:isPlayer() and not alreadyIn then
		saveReturnPos(player)
	end
	local dest = opts.position or LobbyInstance.spawnPosition(room)
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
