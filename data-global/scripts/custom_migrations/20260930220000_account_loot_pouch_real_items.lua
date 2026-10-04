-- IdleOT: the account loot pouch is a regular container again. Convert the old
-- stash-style totals (account_id, item_id, item_count) into real item rows laid
-- out like player_items (pid 0 = direct pouch child). Stackables are split into
-- full stacks; non-stackables become one row each with default subtype/charges.

local m = Migration("20260930220000_account_loot_pouch_real_items")

local TABLE = "account_loot_pouch_items"
local STAGING = "account_loot_pouch_items_staging"
local FIRST_SID = 101
local INSERT_BATCH = 500

local function hasColumn(tableName, column)
	local result = db.storeQuery(string.format("SHOW COLUMNS FROM `%s` LIKE '%s'", tableName, column))
	if not result then
		return false
	end
	Result.free(result)
	return true
end

local function flush(values)
	if #values == 0 then
		return true
	end
	local ok = db.query(string.format("INSERT INTO `%s` (`account_id`, `pid`, `sid`, `itemtype`, `count`, `attributes`) VALUES %s", STAGING, table.concat(values, ",")))
	for i = #values, 1, -1 do
		values[i] = nil
	end
	return ok
end

function m:onExecute()
	if not db.tableExists(TABLE) or not hasColumn(TABLE, "item_id") then
		return true
	end

	logger.info("account_loot_pouch: converting stash totals into real item rows")
	db.query(string.format("DROP TABLE IF EXISTS `%s`", STAGING))
	local created = db.query(string.format(
		[[
		CREATE TABLE `%s` (
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
	]],
		STAGING
	))
	-- error() keeps the migration unmarked so it retries on the next start.
	if not created then
		error("account_loot_pouch: failed to create " .. STAGING)
	end

	local nextSidByAccount = {}
	local values = {}
	local converted = 0
	local result = db.storeQuery(string.format("SELECT `account_id`, `item_id`, `item_count` FROM `%s` ORDER BY `account_id`, `item_id`", TABLE))
	if result then
		repeat
			local accountId = Result.getNumber(result, "account_id")
			local itemId = Result.getNumber(result, "item_id")
			local remaining = Result.getNumber(result, "item_count")
			local itemType = ItemType(itemId)
			if itemType and itemType:getId() ~= 0 and remaining > 0 then
				local stackable = itemType:isStackable()
				local perRow = stackable and math.max(1, itemType:getStackSize() or 100) or 1
				while remaining > 0 do
					local amount = math.min(remaining, perRow)
					local sid = nextSidByAccount[accountId] or FIRST_SID
					nextSidByAccount[accountId] = sid + 1
					values[#values + 1] = string.format("(%d, 0, %d, %d, %d, '')", accountId, sid, itemId, stackable and amount or 0)
					remaining = remaining - amount
					converted = converted + 1
					if #values >= INSERT_BATCH and not flush(values) then
						Result.free(result)
						error("account_loot_pouch: failed to insert converted rows; legacy table left untouched")
					end
				end
			end
		until not Result.next(result)
		Result.free(result)
	end
	if not flush(values) then
		error("account_loot_pouch: failed to insert converted rows; legacy table left untouched")
	end

	if not db.query(string.format("DROP TABLE `%s`", TABLE)) or not db.query(string.format("RENAME TABLE `%s` TO `%s`", STAGING, TABLE)) then
		error("account_loot_pouch: failed to swap " .. STAGING .. " into " .. TABLE)
	end
	logger.info("account_loot_pouch: converted into {} item rows", converted)
	return true
end
m:register()
