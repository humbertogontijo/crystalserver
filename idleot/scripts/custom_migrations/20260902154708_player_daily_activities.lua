-- IdleOT: daily activity progress (player_daily_activities).
local m = Migration("20260902154708_player_daily_activities")
function m:onExecute()
	local cols = db.storeQuery("SHOW TABLES LIKE 'player_daily_activities'")
	if cols then
		Result.free(cols)
		logger.info("player_daily_activities: table already present")
		return
	end

	db.query([[
		CREATE TABLE IF NOT EXISTS `player_daily_activities` (
			`player_id` int NOT NULL,
			`activity_day` varchar(10) NOT NULL DEFAULT '',
			`daily_hunt` int UNSIGNED NOT NULL DEFAULT 0,
			`solo_boss` int UNSIGNED NOT NULL DEFAULT 0,
			`world_boss` int UNSIGNED NOT NULL DEFAULT 0,
			`bounty_hunter` int UNSIGNED NOT NULL DEFAULT 0,
			CONSTRAINT `player_daily_activities_pk` PRIMARY KEY (`player_id`),
			CONSTRAINT `player_daily_activities_players_fk`
				FOREIGN KEY (`player_id`) REFERENCES `players` (`id`)
				ON DELETE CASCADE
		) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4
	]])

	logger.info("Created player_daily_activities")
	return true
end
m:register()
