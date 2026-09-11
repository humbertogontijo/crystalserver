-- IdleOT: fiendish_hunt counter on player_daily_activities.
local m = Migration("20260910180000_player_daily_activities_fiendish_hunt")
function m:onExecute()
	local cols = db.storeQuery("SHOW COLUMNS FROM `player_daily_activities` LIKE 'fiendish_hunt'")
	if cols then
		Result.free(cols)
		logger.info("player_daily_activities.fiendish_hunt: column already present")
		return true
	end

	db.query([[
		ALTER TABLE `player_daily_activities`
			ADD COLUMN `fiendish_hunt` int UNSIGNED NOT NULL DEFAULT 0
			AFTER `bounty_hunter`
	]])

	logger.info("Added player_daily_activities.fiendish_hunt")
	return true
end
m:register()
