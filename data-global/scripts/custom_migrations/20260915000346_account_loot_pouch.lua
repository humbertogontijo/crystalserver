-- IdleOT: one loot pouch per account (per world/DB). Real item rows laid out like
-- player_items (pid 0 = direct pouch child, else parent sid). Empty table only.
-- account_id is UNSIGNED to match accounts.id.
-- DBs created before 20260930220000 hold the old (item_id, item_count) totals;
-- that migration converts them.

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
			`pid` int(11) NOT NULL DEFAULT '0',
			`sid` int(11) NOT NULL DEFAULT '0',
			`itemtype` int(11) NOT NULL DEFAULT '0',
			`count` int(11) NOT NULL DEFAULT '0',
			`attributes` blob NOT NULL,
			CONSTRAINT `account_loot_pouch_items_pk` PRIMARY KEY (`account_id`, `sid`),
			CONSTRAINT `account_loot_pouch_items_owner_fk`
				FOREIGN KEY (`account_id`) REFERENCES `accounts` (`id`)
				ON DELETE CASCADE
		) ENGINE=InnoDB DEFAULT CHARSET=utf8
	]])
	return true
end
m:register()
