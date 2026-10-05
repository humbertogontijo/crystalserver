-- IdleOT: Player Home was replaced by the transient lobby room. Items players kept in
-- their home move into their store inbox, then `player_home_items` is dropped.
-- The seeded starter fixtures (shrines, dummy, mailbox, locker) are not real items.
local FIXTURE_IDS = {
	[25175] = true, -- imbuing shrine
	[25720] = true, -- reward shrine
	[28559] = true, -- exercise dummy
	[23399] = true, -- mailbox
	[3497] = true, -- locker
	[17391] = true,
	[10145] = true,
	[17393] = true,
	[10050] = true,
}

local function inboxSidOffset(playerId)
	local result = db.storeQuery("SELECT MAX(`sid`) AS `maxsid` FROM `player_inboxitems` WHERE `player_id` = " .. playerId)
	local maxSid = 0
	if result then
		maxSid = Result.getNumber(result, "maxsid") or 0
		Result.free(result)
	end
	-- Inbox loading treats pid 0-99 as top level, so nested sids must stay >= 100.
	return math.max(maxSid, 100)
end

local m = Migration("20261005120000_player_home_items_to_inbox")
function m:onExecute()
	local exists = db.storeQuery("SHOW TABLES LIKE 'player_home_items'")
	if not exists then
		return true
	end
	Result.free(exists)

	local byPlayer = {}
	local rows = db.storeQuery("SELECT `player_id`, `sid`, `pid`, `itemtype`, `count`, `attributes` FROM `player_home_items` ORDER BY `player_id`, `sid`")
	if rows then
		repeat
			local playerId = Result.getNumber(rows, "player_id")
			local list = byPlayer[playerId] or {}
			byPlayer[playerId] = list
			list[#list + 1] = {
				sid = Result.getNumber(rows, "sid"),
				pid = Result.getNumber(rows, "pid"),
				itemtype = Result.getNumber(rows, "itemtype"),
				count = Result.getNumber(rows, "count"),
				attributes = Result.getStream(rows, "attributes") or "",
			}
		until not Result.next(rows)
		Result.free(rows)
	end

	local moved, players = 0, 0
	for playerId, list in pairs(byPlayer) do
		local offset = inboxSidOffset(playerId)
		local kept = {}
		local values = {}
		for _, row in ipairs(list) do
			local parentKept = row.pid == 0 or kept[row.pid]
			if parentKept and not FIXTURE_IDS[row.itemtype] then
				kept[row.sid] = true
				values[#values + 1] = string.format(
					"(%d, %d, %d, %d, %d, %s)",
					playerId,
					row.pid == 0 and 0 or (offset + row.pid),
					offset + row.sid,
					row.itemtype,
					row.count,
					db.escapeBlob(row.attributes, #row.attributes)
				)
			end
		end
		if #values > 0 then
			local ok = db.query(
				"INSERT INTO `player_inboxitems` (`player_id`, `pid`, `sid`, `itemtype`, `count`, `attributes`) VALUES "
					.. table.concat(values, ",")
			)
			if not ok then
				logger.error("player_home_items: inbox insert failed for player {}", playerId)
				return false
			end
			moved = moved + #values
			players = players + 1
		end
	end

	db.query("DROP TABLE `player_home_items`")
	logger.info("player_home_items: moved {} item(s) for {} player(s) into inboxes and dropped the table", moved, players)
	return true
end
m:register()
