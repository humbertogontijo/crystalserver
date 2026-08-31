-- IdleOT custom migration (was numbered core *.product).
-- Seed a private starter-home layout per player (shrines, dummy, mailbox).
-- Locker corner stays on the shared instance-0 template — do not seed it here.
-- Layout matches PlayerHomeConfig.starterLayout(); new characters copy these
-- rows via SlenderAAC (see copyTemplateHomeItems). Runtime also stamps a
-- private copy on first visit if this table is empty.

local EMPTY_ATTR = "''"

-- rel_x, rel_y, sid, itemtype
local LAYOUT = {
	{ 0, 0, 1, 25175 }, -- imbuing shrine
	{ 1, 0, 2, 25720 }, -- reward shrine
	{ 5, 1, 3, 28559 }, -- ferumbras exercise dummy
	{ 0, 6, 4, 23399 }, -- mailbox
}

local function buildRows(playerId)
	local rows = {}
	for _, entry in ipairs(LAYOUT) do
		rows[#rows + 1] = string.format(
			"(%d, %d, %d, %d, 0, %d, 1, %s)",
			playerId,
			entry[1],
			entry[2],
			entry[3],
			entry[4],
			EMPTY_ATTR
		)
	end
	return rows
end

local m = Migration("20240830000006_sample_home_items")
function m:onExecute()
	logger.info("Updating database: seed per-player starter home furniture")

	local resultId = db.storeQuery([[
		SELECT `p`.`id` FROM `players` AS `p`
		LEFT JOIN `player_home_items` AS `h` ON `h`.`player_id` = `p`.`id`
		WHERE `h`.`player_id` IS NULL
	]])
	if not resultId then
		logger.info("[sample_home_items] no players need starter home furniture")
		return true
	end

	local playerIds = {}
	repeat
		playerIds[#playerIds + 1] = Result.getNumber(resultId, "id")
	until not Result.next(resultId)
	Result.free(resultId)

	for _, playerId in ipairs(playerIds) do
		local rows = buildRows(playerId)
		local ok = db.query(
			"INSERT INTO `player_home_items` "
				.. "(`player_id`,`rel_x`,`rel_y`,`sid`,`pid`,`itemtype`,`count`,`attributes`) VALUES "
				.. table.concat(rows, ",")
		)
		if not ok then
			logger.error("[sample_home_items] insert failed for player {}", playerId)
			return false
		end
	end

	logger.info("[sample_home_items] seeded starter furniture for {} player(s)", #playerIds)
	return true
end
m:register()
