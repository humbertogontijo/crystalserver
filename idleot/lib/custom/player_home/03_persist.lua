PlayerHomePersist = {}

local function wallIdSet()
	return {
		[PlayerHomeConfig.WALL_H] = true,
		[PlayerHomeConfig.WALL_V] = true,
		[PlayerHomeConfig.WALL_TL] = true,
		[PlayerHomeConfig.WALL_TR] = true,
		[PlayerHomeConfig.WALL_BL] = true,
		[PlayerHomeConfig.WALL_BR] = true,
	}
end

local function shouldSaveItem(item)
	if not item then
		return false
	end
	local id = item:getId()
	if wallIdSet()[id] then
		return false
	end
	if PlayerHomeConfig.isSharedLockerId and PlayerHomeConfig.isSharedLockerId(id) then
		return false
	end
	local tile = item:getTile()
	if tile and tile:getGround() == item then
		return false
	end
	-- Starter house furniture always persist (player may rearrange).
	if PlayerHomeConfig.isFurnitureId and PlayerHomeConfig.isFurnitureId(id) then
		return true
	end
	if item:isContainer() then
		return true
	end
	if item:canBeMoved() then
		return true
	end
	local it = ItemType(id)
	if it then
		if it:isPickupable() or it:isMovable() then
			return true
		end
		if it.isWrapable and it:isWrapable() then
			return true
		end
	end
	if item:getCustomAttribute("unWrapId") then
		return true
	end
	return false
end

--- Walk stack recursively into sid/pid rows (attribute blobs).
local function appendItems(rows, parentSid, items, nextSid, instanceId)
	if not items then
		return nextSid
	end
	for _, item in ipairs(items) do
		if item and item.getInstanceId and item:getInstanceId() == instanceId and shouldSaveItem(item) then
			local sid = nextSid
			nextSid = nextSid + 1
			local attrs = ""
			if item.serializeAttributes then
				attrs = item:serializeAttributes() or ""
			end
			rows[#rows + 1] = {
				sid = sid,
				pid = parentSid,
				itemtype = item:getId(),
				count = item:getCount() or 1,
				attributes = attrs,
			}
			if item:isContainer() then
				-- Container methods live on the Item userdata in Crystal Lua bindings.
				local size = item:getSize() or 0
				local children = {}
				for i = 0, size - 1 do
					local child = item:getItem(i)
					if child then
						children[#children + 1] = child
					end
				end
				nextSid = appendItems(rows, sid, children, nextSid, instanceId)
			end
		end
	end
	return nextSid
end

function PlayerHomePersist.serializeInstance(instance)
	if not instance or not instance.floorOrigin or not instance.instanceId then
		return {}
	end
	local fo = instance.floorOrigin
	local size = instance.floorSize or PlayerHomeConfig.FLOOR_SIZE
	local instanceId = instance.instanceId
	local out = {}
	local nextSid = 1

	for ry = 0, size - 1 do
		for rx = 0, size - 1 do
			local pos = Position(fo.x + rx, fo.y + ry, fo.z)
			local tile = Tile(pos)
			if tile then
				local items = tile:getItems()
				if items and #items > 0 then
					local tileRows = {}
					nextSid = appendItems(tileRows, 0, items, nextSid, instanceId)
					for _, row in ipairs(tileRows) do
						out[#out + 1] = {
							rel_x = rx,
							rel_y = ry,
							sid = row.sid,
							pid = row.pid,
							itemtype = row.itemtype,
							count = row.count,
							attributes = row.attributes,
						}
					end
				end
			end
		end
	end
	return out
end

function PlayerHomePersist.savePlayer(player, instance)
	if not player or not instance then
		return false
	end
	local guid = player:getGuid()
	if not guid or guid == 0 then
		return false
	end

	local rows = PlayerHomePersist.serializeInstance(instance)
	db.query("DELETE FROM `player_home_items` WHERE `player_id` = " .. guid)

	if #rows == 0 then
		return true
	end

	local parts = {}
	for _, row in ipairs(rows) do
		local attrs = row.attributes or ""
		local escaped = db.escapeBlob(attrs, #attrs)
		parts[#parts + 1] = string.format(
			"(%d,%d,%d,%d,%d,%d,%d,%s)",
			guid,
			row.rel_x,
			row.rel_y,
			row.sid,
			row.pid,
			row.itemtype,
			row.count,
			escaped
		)
	end

	local sql = "INSERT INTO `player_home_items` "
		.. "(`player_id`,`rel_x`,`rel_y`,`sid`,`pid`,`itemtype`,`count`,`attributes`) VALUES "
		.. table.concat(parts, ",")
	return db.query(sql) ~= false
end

local function applyAttributes(item, attributes)
	if not item or not attributes or attributes == "" then
		return
	end
	if item.unserializeAttributes then
		item:unserializeAttributes(attributes)
	else
		logger.warn(
			"[PlayerHome] Item:unserializeAttributes missing - rebuild CrystalServer; attributes incomplete for item {}",
			item:getId()
		)
	end
end

function PlayerHomePersist.hasItems(player)
	if not player then
		return false
	end
	local guid = player:getGuid()
	if not guid or guid == 0 then
		return false
	end
	local resultId = db.storeQuery(
		"SELECT `sid` FROM `player_home_items` WHERE `player_id` = " .. guid .. " LIMIT 1"
	)
	if not resultId then
		return false
	end
	Result.free(resultId)
	return true
end

function PlayerHomePersist.loadPlayer(player, instance)
	if not player or not instance then
		return 0
	end
	local guid = player:getGuid()
	if not guid or guid == 0 then
		return 0
	end

	local resultId = db.storeQuery(
		"SELECT `rel_x`,`rel_y`,`sid`,`pid`,`itemtype`,`count`,`attributes` FROM `player_home_items` WHERE `player_id` = "
			.. guid
			.. " ORDER BY `sid` ASC"
	)
	if not resultId then
		return 0
	end

	local rows = {}
	repeat
		local attrs = Result.getStream(resultId, "attributes") or ""
		rows[#rows + 1] = {
			rel_x = Result.getNumber(resultId, "rel_x"),
			rel_y = Result.getNumber(resultId, "rel_y"),
			sid = Result.getNumber(resultId, "sid"),
			pid = Result.getNumber(resultId, "pid"),
			itemtype = Result.getNumber(resultId, "itemtype"),
			count = Result.getNumber(resultId, "count"),
			attributes = attrs,
		}
	until not Result.next(resultId)
	Result.free(resultId)

	local fo = instance.floorOrigin
	local bySid = {}
	local placed = 0

	-- Create items first (no parent yet). Shared locker fixtures stay on the template.
	for _, row in ipairs(rows) do
		if not (PlayerHomeConfig.isSharedLockerId and PlayerHomeConfig.isSharedLockerId(row.itemtype)) then
			local item = Game.createItem(row.itemtype, math.max(1, row.count or 1))
			if item then
				applyAttributes(item, row.attributes)
				if instance.instanceId and item.setInstanceId then
					item:setInstanceId(instance.instanceId)
				end
				bySid[row.sid] = { item = item, row = row }
			end
		end
	end

	-- Place top-level on tiles; nest children into containers
	for _, row in ipairs(rows) do
		local entry = bySid[row.sid]
		if entry and entry.item then
			if row.pid and row.pid > 0 then
				local parentEntry = bySid[row.pid]
				if parentEntry and parentEntry.item and parentEntry.item:isContainer() then
					parentEntry.item:addItemEx(entry.item)
				end
			else
				local pos = Position(fo.x + row.rel_x, fo.y + row.rel_y, fo.z)
				if instance.house and instance.house.addTile then
					instance.house:addTile(pos)
				elseif not Tile(pos) then
					Game.createTile(pos, true)
				end
				entry.item:moveTo(pos)
				if instance.instanceId and entry.item.setInstanceId then
					entry.item:setInstanceId(instance.instanceId)
				end
				placed = placed + 1
			end
		end
	end

	return placed
end
