-- IdleOT custom migration (was numbered core *.product).
-- Seed vocation starter kit + store inbox on "* Sample" characters.
-- Loot pouch is account-scoped (see account_loot_pouch migration); not seeded here.
-- Dev-only seed; real characters get their kit from scripts/idleot/starter_kit.

local STORE_INBOX_ID = 23396
local BACKPACK_ID = 2854

local SLOT_HEAD = 1
local SLOT_NECKLACE = 2
local SLOT_BACKPACK = 3
local SLOT_ARMOR = 4
local SLOT_RIGHT = 5
local SLOT_LEFT = 6
local SLOT_LEGS = 7
local SLOT_FEET = 8
local SLOT_STORE_INBOX = 11

local EMPTY_ATTR = "''"

-- slot -> itemtype for equipped gear (backpack/store inbox added separately)
local KITS = {
	[0] = {
		name = "Rook Sample",
		equipped = {},
		container = {
			{ 3003, 1 },
			{ 3457, 1 },
		},
	},
	[1] = {
		name = "Sorcerer Sample",
		equipped = {
			{ SLOT_HEAD, 7992 },
			{ SLOT_NECKLACE, 3572 },
			{ SLOT_ARMOR, 7991 },
			{ SLOT_RIGHT, 3059 },
			{ SLOT_LEFT, 3074 },
			{ SLOT_LEGS, 3362 },
			{ SLOT_FEET, 3552 },
		},
		container = {
			{ 3003, 1 },
			{ 5710, 1 },
			{ 268, 10 },
		},
	},
	[2] = {
		name = "Druid Sample",
		equipped = {
			{ SLOT_HEAD, 7992 },
			{ SLOT_NECKLACE, 3572 },
			{ SLOT_ARMOR, 7991 },
			{ SLOT_RIGHT, 3059 },
			{ SLOT_LEFT, 3066 },
			{ SLOT_LEGS, 3362 },
			{ SLOT_FEET, 3552 },
		},
		container = {
			{ 3003, 1 },
			{ 5710, 1 },
			{ 268, 10 },
		},
	},
	[3] = {
		name = "Paladin Sample",
		equipped = {
			{ SLOT_HEAD, 3374 },
			{ SLOT_NECKLACE, 3572 },
			{ SLOT_ARMOR, 3571 },
			{ SLOT_RIGHT, 35562 }, -- quiver
			{ SLOT_LEFT, 3350 }, -- bow
			{ SLOT_LEGS, 8095 },
			{ SLOT_FEET, 3552 },
		},
		-- Nested in equipped containers (pid = parent item sid)
		equippedContents = {
			[SLOT_RIGHT] = {
				{ 3447, 50 }, -- arrows in quiver
			},
		},
		container = {
			{ 3003, 1 },
			{ 5710, 1 },
			{ 266, 10 },
			{ 3277, 1 }, -- spear
			{ 3425, 1 }, -- dwarven shield
		},
	},
	[4] = {
		name = "Knight Sample",
		equipped = {
			{ SLOT_HEAD, 3354 },
			{ SLOT_NECKLACE, 3572 },
			{ SLOT_ARMOR, 3359 },
			{ SLOT_RIGHT, 3425 },
			{ SLOT_LEFT, 7773 },
			{ SLOT_LEGS, 3372 },
			{ SLOT_FEET, 3552 },
		},
		container = {
			{ 7774, 1 },
			{ 3327, 1 },
			{ 3003, 1 },
			{ 5710, 1 },
			{ 266, 10 },
		},
	},
	[9] = {
		name = "Monk Sample",
		equipped = {
			{ SLOT_HEAD, 3354 },
			{ SLOT_NECKLACE, 3572 },
			{ SLOT_ARMOR, 3359 },
			{ SLOT_LEFT, 50171 },
			{ SLOT_LEGS, 3372 },
			{ SLOT_FEET, 3552 },
		},
		container = {
			{ 3425, 1 },
			{ 3003, 1 },
			{ 5710, 1 },
			{ 266, 10 },
		},
	},
}

local function nextSid(counter)
	counter[1] = counter[1] + 1
	return counter[1]
end

local function buildRows(playerId, kit)
	local rows = {}
	local sidCounter = { 100 }

	local slotToSid = {}

	for _, entry in ipairs(kit.equipped or {}) do
		local slot, itemType = entry[1], entry[2]
		local sid = nextSid(sidCounter)
		slotToSid[slot] = sid
		rows[#rows + 1] = string.format(
			"(%d, %d, %d, %d, %d, %s)",
			playerId,
			slot,
			sid,
			itemType,
			1,
			EMPTY_ATTR
		)
	end

	local backpackSid = nextSid(sidCounter)
	slotToSid[SLOT_BACKPACK] = backpackSid
	rows[#rows + 1] = string.format(
		"(%d, %d, %d, %d, %d, %s)",
		playerId,
		SLOT_BACKPACK,
		backpackSid,
		BACKPACK_ID,
		1,
		EMPTY_ATTR
	)

	for slot, contents in pairs(kit.equippedContents or {}) do
		local parentSid = slotToSid[slot]
		if parentSid then
			for _, entry in ipairs(contents) do
				local itemType, count = entry[1], entry[2]
				local sid = nextSid(sidCounter)
				rows[#rows + 1] = string.format(
					"(%d, %d, %d, %d, %d, %s)",
					playerId,
					parentSid,
					sid,
					itemType,
					count,
					EMPTY_ATTR
				)
			end
		end
	end

	for _, entry in ipairs(kit.container or {}) do
		local itemType, count = entry[1], entry[2]
		local sid = nextSid(sidCounter)
		rows[#rows + 1] = string.format(
			"(%d, %d, %d, %d, %d, %s)",
			playerId,
			backpackSid,
			sid,
			itemType,
			count,
			EMPTY_ATTR
		)
	end

	local inboxSid = nextSid(sidCounter)
	slotToSid[SLOT_STORE_INBOX] = inboxSid
	rows[#rows + 1] = string.format(
		"(%d, %d, %d, %d, %d, %s)",
		playerId,
		SLOT_STORE_INBOX,
		inboxSid,
		STORE_INBOX_ID,
		1,
		EMPTY_ATTR
	)

	return rows
end

local m = Migration("20240830000005_sample_starter_items")
function m:onExecute()
	-- Skip re-seed if Sample kits already exist (numbered-core 69 already ran).
	local existing = db.storeQuery([[
		SELECT COUNT(*) AS `n` FROM `player_items` AS `i`
		INNER JOIN `players` AS `p` ON `p`.`id` = `i`.`player_id`
		WHERE `p`.`name` LIKE '% Sample'
	]])
	if existing then
		local n = Result.getNumber(existing, "n")
		Result.free(existing)
		if n > 0 then
			logger.info("sample_starter_items: already seeded ({} rows)", n)
			return
		end
	end
	logger.info("Updating database: seed Sample character starter items (kit + store inbox)")

	db.query([[
		DELETE FROM `player_items`
		WHERE `player_id` IN (SELECT `id` FROM `players` WHERE `name` LIKE '% Sample');
	]])

	local totalRows = 0
	for vocationId, kit in pairs(KITS) do
		local resultId = db.storeQuery(
			string.format("SELECT `id` FROM `players` WHERE `name` = %s LIMIT 1", db.escapeString(kit.name))
		)
		if not resultId then
			logger.warn("[sample_starter_items] missing player {}", kit.name)
		else
			local playerId = Result.getNumber(resultId, "id")
			Result.free(resultId)

			local rows = buildRows(playerId, kit)
			if #rows > 0 then
				local sql = string.format(
					"INSERT INTO `player_items` (`player_id`, `pid`, `sid`, `itemtype`, `count`, `attributes`) VALUES %s",
					table.concat(rows, ",\n")
				)
				if not db.query(sql) then
					logger.error("[sample_starter_items] insert failed for {} (vocation {})", kit.name, vocationId)
					return false
				end
				totalRows = totalRows + #rows
				logger.info("[sample_starter_items] {} -> {} item rows", kit.name, #rows)
			end
		end
	end

	logger.info("[sample_starter_items] done ({} rows total)", totalRows)
	return true
end
m:register()
