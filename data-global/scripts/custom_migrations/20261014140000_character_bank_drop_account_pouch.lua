-- IdleOT: restore character-scoped bank (Crystal upstream) and drop the account loot pouch.
-- Moves accounts.balance onto each account's oldest character (MIN(players.id)), then drops
-- accounts.balance and account_loot_pouch_items. Pouch contents are intentionally abandoned.

local m = Migration("20261014140000_character_bank_drop_account_pouch")

function m:onExecute()
	local cols = db.storeQuery("SHOW COLUMNS FROM `accounts` LIKE 'balance'")
	if cols then
		Result.free(cols)
		logger.info("character_bank: redistributing accounts.balance onto oldest characters")
		db.query([[
			UPDATE `players` AS `p`
			INNER JOIN (
				SELECT `account_id`, MIN(`id`) AS `oldest_id`
				FROM `players`
				GROUP BY `account_id`
			) AS `o` ON `o`.`oldest_id` = `p`.`id`
			INNER JOIN `accounts` AS `a` ON `a`.`id` = `p`.`account_id`
			SET `p`.`balance` = `p`.`balance` + `a`.`balance`
			WHERE `a`.`balance` > 0
		]])
		db.query("UPDATE `accounts` SET `balance` = 0")
		db.query("ALTER TABLE `accounts` DROP COLUMN `balance`")
		logger.info("character_bank: dropped accounts.balance")
	else
		logger.info("character_bank: accounts.balance already absent")
	end

	local tables = db.storeQuery("SHOW TABLES LIKE 'account_loot_pouch_items'")
	if tables then
		Result.free(tables)
		db.query("DROP TABLE `account_loot_pouch_items`")
		logger.info("character_bank: dropped account_loot_pouch_items")
	else
		logger.info("character_bank: account_loot_pouch_items already absent")
	end

	return true
end

m:register()
