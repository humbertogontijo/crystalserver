-- IdleOT: one loot pouch per account (per world/DB), stash-style map storage
-- like player_stash (account_id, item_id, item_count). Empty table only.
-- account_id is UNSIGNED to match accounts.id.

local m = Migration("20260915000346_account_loot_pouch")

function m:onExecute()
	local rows = db.storeQuery("SHOW TABLES LIKE 'account_loot_pouch_items'")
	if rows then
		Result.free(rows)
		logger.info("account_loot_pouch: account_loot_pouch_items already present")
		return true
	end

	logger.info("account_loot_pouch: creating account_loot_pouch_items")
	db.query([[
		CREATE TABLE `account_loot_pouch_items` (
			`account_id` int(11) UNSIGNED NOT NULL,
			`item_id` int(11) NOT NULL,
			`item_count` int(11) NOT NULL DEFAULT 0,
			CONSTRAINT `account_loot_pouch_items_unique` UNIQUE (`account_id`, `item_id`),
			CONSTRAINT `account_loot_pouch_items_accounts_fk`
				FOREIGN KEY (`account_id`) REFERENCES `accounts` (`id`)
				ON DELETE CASCADE
		) ENGINE=InnoDB DEFAULT CHARSET=utf8
	]])
	return true
end
m:register()
