-- IdleOT custom migration (was numbered core *.product).
local m = Migration("20240830000001_account_bank_balance")
function m:onExecute()
	-- Idempotent: skip if the numbered-core migration already added the column.
	local cols = db.storeQuery("SHOW COLUMNS FROM `accounts` LIKE 'balance'")
	if cols then
		Result.free(cols)
		logger.info("account_bank_balance: accounts.balance already present")
		return
	end
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
m:register()
