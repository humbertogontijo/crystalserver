-- IdleOT: daily_reward_history.description overflows varchar(255) when listing
-- many picked items (MySQL 1406). Match forge_history and store as TEXT.
local m = Migration("20260903044555_daily_reward_history_description")
function m:onExecute()
	local cols = db.storeQuery("SHOW COLUMNS FROM `daily_reward_history` LIKE 'description'")
	if not cols then
		logger.warn("daily_reward_history_description: table/column missing — skip")
		return
	end
	local colType = Result.getString(cols, "Type")
	Result.free(cols)
	if colType and string.find(string.lower(colType), "text", 1, true) then
		logger.info("daily_reward_history.description already TEXT ({})", colType)
		return
	end

	db.query("ALTER TABLE `daily_reward_history` MODIFY COLUMN `description` text DEFAULT NULL")
	logger.info("Widened daily_reward_history.description to TEXT")
	return true
end
m:register()
