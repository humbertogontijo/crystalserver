-- CIP Friend System (account-scoped lists for S 0x74 / C 0x81).
local m = Migration("20261023220000_account_friend_system")

function m:onExecute()
	db.query([[
CREATE TABLE IF NOT EXISTS `account_friends` (
	`account_id` int unsigned NOT NULL,
	`friend_account_id` int unsigned NOT NULL,
	`group` tinyint unsigned NOT NULL DEFAULT 2,
	`created` int unsigned NOT NULL,
	PRIMARY KEY (`account_id`, `friend_account_id`),
	KEY `idx_account_friends_friend` (`friend_account_id`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8;]])

	db.query([[
CREATE TABLE IF NOT EXISTS `account_friend_invites` (
	`from_account_id` int unsigned NOT NULL,
	`to_account_id` int unsigned NOT NULL,
	`created` int unsigned NOT NULL,
	PRIMARY KEY (`from_account_id`, `to_account_id`),
	KEY `idx_account_friend_invites_to` (`to_account_id`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8;]])

	db.query([[
CREATE TABLE IF NOT EXISTS `account_friend_blacklist` (
	`account_id` int unsigned NOT NULL,
	`blocked_account_id` int unsigned NOT NULL,
	`created` int unsigned NOT NULL,
	PRIMARY KEY (`account_id`, `blocked_account_id`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8;]])

	db.query([[
CREATE TABLE IF NOT EXISTS `account_friend_settings` (
	`account_id` int unsigned NOT NULL,
	`setting_type` tinyint unsigned NOT NULL,
	`show_character` tinyint unsigned NOT NULL DEFAULT 1,
	`show_account` tinyint unsigned NOT NULL DEFAULT 1,
	`allow_inspect` tinyint unsigned NOT NULL DEFAULT 1,
	`enable_character` tinyint unsigned NOT NULL DEFAULT 1,
	`enable_account` tinyint unsigned NOT NULL DEFAULT 1,
	`enable_inspect` tinyint unsigned NOT NULL DEFAULT 1,
	PRIMARY KEY (`account_id`, `setting_type`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8;]])

	logger.info("account_friend_system: tables ready")
	return true
end

m:register()
