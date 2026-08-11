function onUpdateDatabase()
	logger.info("Updating database to version 65 (player personal home item storage)")

	db.query([[
		CREATE TABLE IF NOT EXISTS `player_home_items` (
			`player_id` int(11) NOT NULL,
			`rel_x` tinyint(3) unsigned NOT NULL DEFAULT 0,
			`rel_y` tinyint(3) unsigned NOT NULL DEFAULT 0,
			`sid` int(11) NOT NULL DEFAULT 0,
			`pid` int(11) NOT NULL DEFAULT 0,
			`itemtype` int(11) NOT NULL DEFAULT 0,
			`count` int(11) NOT NULL DEFAULT 0,
			`attributes` blob NOT NULL,
			PRIMARY KEY (`player_id`, `sid`),
			INDEX `player_home_items_player_id` (`player_id`),
			CONSTRAINT `player_home_items_players_fk`
				FOREIGN KEY (`player_id`) REFERENCES `players` (`id`)
				ON DELETE CASCADE
		) ENGINE=InnoDB DEFAULT CHARSET=utf8;
	]])

	return true
end
