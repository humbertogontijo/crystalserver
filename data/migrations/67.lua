function onUpdateDatabase()
	logger.info("Updating database to version N (account shared bank balance per world)")

	-- One DB == one world: share bank gold across all characters on an account.
	db.query([[
		ALTER TABLE `accounts`
		ADD COLUMN `balance` bigint(20) UNSIGNED NOT NULL DEFAULT 0
		AFTER `tournament_coins`
	]])

	db.query([[
		UPDATE `accounts` AS `a`
		SET `a`.`balance` = (
			SELECT COALESCE(SUM(`p`.`balance`), 0)
			FROM `players` AS `p`
			WHERE `p`.`account_id` = `a`.`id`
		)
	]])

	-- Character column is no longer authoritative (kept for schema compatibility).
	db.query([[
		UPDATE `players` SET `balance` = 0
	]])

	return true
end
