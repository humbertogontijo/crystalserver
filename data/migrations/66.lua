function onUpdateDatabase()
	logger.info("Updating database to version 66 (normalize player_spells names to lowercase)")

	-- learnInstantSpell / hasLearnedInstantSpell always use lowercase. Title-case
	-- rows from sample-spell migrations miss the in-memory set lookup and get
	-- re-learned, then save fails on PRIMARY KEY under case-insensitive collation.
	db.query([[
		UPDATE `player_spells`
		SET `name` = LOWER(`name`)
		WHERE `name` <> LOWER(`name`);
	]])

	return true
end
