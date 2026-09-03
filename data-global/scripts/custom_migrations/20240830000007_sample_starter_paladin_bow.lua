-- IdleOT custom migration (was numbered core *.product).
-- Re-seed Paladin Sample: equip bow + quiver (arrows inside).
-- Migration 69 left spear/shield equipped and bow loose in the backpack.

local STORE_INBOX_ID = 23396
local LOOT_POUCH_ID = 23721
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
local SAMPLE_NAME = "Paladin Sample"

local kit = {
	equipped = {
		{ SLOT_HEAD, 3374 },
		{ SLOT_NECKLACE, 3572 },
		{ SLOT_ARMOR, 3571 },
		{ SLOT_RIGHT, 35562 }, -- quiver
		{ SLOT_LEFT, 3350 }, -- bow
		{ SLOT_LEGS, 8095 },
		{ SLOT_FEET, 3552 },
	},
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
}

local function nextSid(counter)
	counter[1] = counter[1] + 1
	return counter[1]
end

local function buildRows(playerId)
	local rows = {}
	local sidCounter = { 100 }
	local slotToSid = {}

	for _, entry in ipairs(kit.equipped) do
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
	rows[#rows + 1] = string.format(
		"(%d, %d, %d, %d, %d, %s)",
		playerId,
		SLOT_BACKPACK,
		backpackSid,
		BACKPACK_ID,
		1,
		EMPTY_ATTR
	)

	for slot, contents in pairs(kit.equippedContents) do
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

	for _, entry in ipairs(kit.container) do
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
	rows[#rows + 1] = string.format(
		"(%d, %d, %d, %d, %d, %s)",
		playerId,
		SLOT_STORE_INBOX,
		inboxSid,
		STORE_INBOX_ID,
		1,
		EMPTY_ATTR
	)

	local pouchSid = nextSid(sidCounter)
	rows[#rows + 1] = string.format(
		"(%d, %d, %d, %d, %d, %s)",
		playerId,
		inboxSid,
		pouchSid,
		LOOT_POUCH_ID,
		1,
		EMPTY_ATTR
	)

	return rows
end

local m = Migration("20240830000007_sample_starter_paladin_bow")
function m:onExecute()
	-- Skip if Paladin Sample already has the bow equipped (numbered-core 71).
	local existing = db.storeQuery([[
		SELECT `i`.`itemtype` FROM `player_items` AS `i`
		INNER JOIN `players` AS `p` ON `p`.`id` = `i`.`player_id`
		WHERE `p`.`name` = 'Paladin Sample' AND `i`.`pid` = 6 AND `i`.`itemtype` = 3350
		LIMIT 1
	]])
	if existing then
		Result.free(existing)
		logger.info("sample_starter_paladin_bow: already equipped")
		return
	end
	logger.info("Updating database: Paladin Sample starter kit → bow + quiver")

	local resultId = db.storeQuery(
		string.format("SELECT `id` FROM `players` WHERE `name` = %s LIMIT 1", db.escapeString(SAMPLE_NAME))
	)
	if not resultId then
		logger.warn("[sample_starter_paladin_bow] missing player {}", SAMPLE_NAME)
		return true
	end

	local playerId = Result.getNumber(resultId, "id")
	Result.free(resultId)

	db.query(string.format("DELETE FROM `player_items` WHERE `player_id` = %d", playerId))

	local rows = buildRows(playerId)
	local sql = string.format(
		"INSERT INTO `player_items` (`player_id`, `pid`, `sid`, `itemtype`, `count`, `attributes`) VALUES %s",
		table.concat(rows, ",\n")
	)
	if not db.query(sql) then
		logger.error("[sample_starter_paladin_bow] insert failed for {}", SAMPLE_NAME)
		return false
	end

	logger.info("[sample_starter_paladin_bow] {} -> {} item rows", SAMPLE_NAME, #rows)
	return true
end
m:register()
