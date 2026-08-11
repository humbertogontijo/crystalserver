function onUpdateDatabase()
	logger.info("Updating database to version 64 (teach all instant spells to Sample characters)")

	-- Premium for god/sample account (Energy Strike and other premium spells).
	db.query([[
		UPDATE `accounts`
		SET `premdays` = GREATEST(COALESCE(`premdays`, 0), 365)
		WHERE `id` = 1;
	]])

	-- Teach every registered instant spell to all "* Sample" players.
	-- INSERT IGNORE keeps the migration idempotent if rows already exist.
	local ok = db.query([[
		INSERT IGNORE INTO `player_spells` (`player_id`, `name`)
		SELECT `p`.`id`, `s`.`name`
		FROM `players` AS `p`
		CROSS JOIN (
			SELECT 'Animate Dead Rune' AS `name`
		UNION ALL SELECT 'Annihilation' AS `name`
		UNION ALL SELECT 'Apprentice''s Strike' AS `name`
		UNION ALL SELECT 'Arrow Call' AS `name`
		UNION ALL SELECT 'Avalanche Rune' AS `name`
		UNION ALL SELECT 'Avatar of Balance' AS `name`
		UNION ALL SELECT 'Avatar of Light' AS `name`
		UNION ALL SELECT 'Avatar of Nature' AS `name`
		UNION ALL SELECT 'Avatar of Steel' AS `name`
		UNION ALL SELECT 'Avatar of Storm' AS `name`
		UNION ALL SELECT 'Balanced Brawl' AS `name`
		UNION ALL SELECT 'Berserk' AS `name`
		UNION ALL SELECT 'Blank Rune' AS `name`
		UNION ALL SELECT 'Blood Rage' AS `name`
		UNION ALL SELECT 'Bruise Bane' AS `name`
		UNION ALL SELECT 'Brutal Strike' AS `name`
		UNION ALL SELECT 'Buzz' AS `name`
		UNION ALL SELECT 'Cancel Invisibility' AS `name`
		UNION ALL SELECT 'Cancel Magic Shield' AS `name`
		UNION ALL SELECT 'Chained Penance' AS `name`
		UNION ALL SELECT 'Challenge' AS `name`
		UNION ALL SELECT 'Chameleon Rune' AS `name`
		UNION ALL SELECT 'Charge' AS `name`
		UNION ALL SELECT 'Chill Out' AS `name`
		UNION ALL SELECT 'Chivalrous Challenge' AS `name`
		UNION ALL SELECT 'Conjure Arrow' AS `name`
		UNION ALL SELECT 'Conjure Bolt' AS `name`
		UNION ALL SELECT 'Conjure Explosive Arrow' AS `name`
		UNION ALL SELECT 'Conjure Piercing Bolt' AS `name`
		UNION ALL SELECT 'Conjure Poisoned Arrow' AS `name`
		UNION ALL SELECT 'Conjure Power Bolt' AS `name`
		UNION ALL SELECT 'Conjure Royal Star' AS `name`
		UNION ALL SELECT 'Conjure Sniper Arrow' AS `name`
		UNION ALL SELECT 'Conjure Wand of Darkness' AS `name`
		UNION ALL SELECT 'Convince Creature Rune' AS `name`
		UNION ALL SELECT 'Creature Illusion' AS `name`
		UNION ALL SELECT 'Cure Bleeding' AS `name`
		UNION ALL SELECT 'Cure Burning' AS `name`
		UNION ALL SELECT 'Cure Curse' AS `name`
		UNION ALL SELECT 'Cure Electrification' AS `name`
		UNION ALL SELECT 'Cure Poison' AS `name`
		UNION ALL SELECT 'Cure Poison Rune' AS `name`
		UNION ALL SELECT 'Curse' AS `name`
		UNION ALL SELECT 'Death Strike' AS `name`
		UNION ALL SELECT 'Destroy Field Rune' AS `name`
		UNION ALL SELECT 'Devastating Knockout' AS `name`
		UNION ALL SELECT 'Disintegrate Rune' AS `name`
		UNION ALL SELECT 'Divine Caldera' AS `name`
		UNION ALL SELECT 'Divine Dazzle' AS `name`
		UNION ALL SELECT 'Divine Empowerment' AS `name`
		UNION ALL SELECT 'Divine Grenade' AS `name`
		UNION ALL SELECT 'Divine Healing' AS `name`
		UNION ALL SELECT 'Divine Missile' AS `name`
		UNION ALL SELECT 'Double Jab' AS `name`
		UNION ALL SELECT 'Druid familiar' AS `name`
		UNION ALL SELECT 'Electrify' AS `name`
		UNION ALL SELECT 'Enchant Party' AS `name`
		UNION ALL SELECT 'Enchant Spear' AS `name`
		UNION ALL SELECT 'Enchant Staff' AS `name`
		UNION ALL SELECT 'Energy Beam' AS `name`
		UNION ALL SELECT 'Energy Bomb Rune' AS `name`
		UNION ALL SELECT 'Energy Field Rune' AS `name`
		UNION ALL SELECT 'Energy Strike' AS `name`
		UNION ALL SELECT 'Energy Wall Rune' AS `name`
		UNION ALL SELECT 'Energy Wave' AS `name`
		UNION ALL SELECT 'Enlighten Party' AS `name`
		UNION ALL SELECT 'Envenom' AS `name`
		UNION ALL SELECT 'Eternal Winter' AS `name`
		UNION ALL SELECT 'Ethereal Spear' AS `name`
		UNION ALL SELECT 'Executioner''s Throw' AS `name`
		UNION ALL SELECT 'Explosion Rune' AS `name`
		UNION ALL SELECT 'Expose Weakness' AS `name`
		UNION ALL SELECT 'Fair Wound Cleansing' AS `name`
		UNION ALL SELECT 'Fierce Berserk' AS `name`
		UNION ALL SELECT 'Find Fiend' AS `name`
		UNION ALL SELECT 'Find Person' AS `name`
		UNION ALL SELECT 'Fire Bomb Rune' AS `name`
		UNION ALL SELECT 'Fire Field Rune' AS `name`
		UNION ALL SELECT 'Fire Wall Rune' AS `name`
		UNION ALL SELECT 'Fire Wave' AS `name`
		UNION ALL SELECT 'Fireball Rune' AS `name`
		UNION ALL SELECT 'Flame Strike' AS `name`
		UNION ALL SELECT 'Flurry of Blows' AS `name`
		UNION ALL SELECT 'Focus Harmony' AS `name`
		UNION ALL SELECT 'Focus Serenity' AS `name`
		UNION ALL SELECT 'Food' AS `name`
		UNION ALL SELECT 'Forceful Uppercut' AS `name`
		UNION ALL SELECT 'Front Sweep' AS `name`
		UNION ALL SELECT 'Great Death Beam' AS `name`
		UNION ALL SELECT 'Great Energy Beam' AS `name`
		UNION ALL SELECT 'Great Fire Wave' AS `name`
		UNION ALL SELECT 'Great Fireball Rune' AS `name`
		UNION ALL SELECT 'Great Light' AS `name`
		UNION ALL SELECT 'Greater Flurry of Blows' AS `name`
		UNION ALL SELECT 'Greater Tiger Clash' AS `name`
		UNION ALL SELECT 'Groundshaker' AS `name`
		UNION ALL SELECT 'Haste' AS `name`
		UNION ALL SELECT 'Heal Friend' AS `name`
		UNION ALL SELECT 'Heal Malice' AS `name`
		UNION ALL SELECT 'Heal Monster' AS `name`
		UNION ALL SELECT 'Heal Monster 9x9' AS `name`
		UNION ALL SELECT 'Heal Party' AS `name`
		UNION ALL SELECT 'Heavy Magic Missile Rune' AS `name`
		UNION ALL SELECT 'Hell''s Core' AS `name`
		UNION ALL SELECT 'Holy Flash' AS `name`
		UNION ALL SELECT 'Holy Missile Rune' AS `name`
		UNION ALL SELECT 'House Door List' AS `name`
		UNION ALL SELECT 'House Guest List' AS `name`
		UNION ALL SELECT 'House Kick' AS `name`
		UNION ALL SELECT 'House Subowner List' AS `name`
		UNION ALL SELECT 'Ice Burst' AS `name`
		UNION ALL SELECT 'Ice Strike' AS `name`
		UNION ALL SELECT 'Ice Wave' AS `name`
		UNION ALL SELECT 'Icicle Rune' AS `name`
		UNION ALL SELECT 'Ignite' AS `name`
		UNION ALL SELECT 'Inflict Wound' AS `name`
		UNION ALL SELECT 'Intense Healing' AS `name`
		UNION ALL SELECT 'Intense Healing Rune' AS `name`
		UNION ALL SELECT 'Intense Recovery' AS `name`
		UNION ALL SELECT 'Intense Wound Cleansing' AS `name`
		UNION ALL SELECT 'Invisibility' AS `name`
		UNION ALL SELECT 'Knight familiar' AS `name`
		UNION ALL SELECT 'Lesser Ethereal Spear' AS `name`
		UNION ALL SELECT 'Lesser Front Sweep' AS `name`
		UNION ALL SELECT 'Levitate' AS `name`
		UNION ALL SELECT 'Light' AS `name`
		UNION ALL SELECT 'Light Healing' AS `name`
		UNION ALL SELECT 'Light Magic Missile Rune' AS `name`
		UNION ALL SELECT 'Light Stone Shower Rune' AS `name`
		UNION ALL SELECT 'Lightest Magic Missile' AS `name`
		UNION ALL SELECT 'Lightest Missile Rune' AS `name`
		UNION ALL SELECT 'Lightning' AS `name`
		UNION ALL SELECT 'Magic Patch' AS `name`
		UNION ALL SELECT 'Magic Rope' AS `name`
		UNION ALL SELECT 'Magic Shield' AS `name`
		UNION ALL SELECT 'Magic Wall Rune' AS `name`
		UNION ALL SELECT 'Mass Healing' AS `name`
		UNION ALL SELECT 'Mass Spirit Mend' AS `name`
		UNION ALL SELECT 'Mentor Other' AS `name`
		UNION ALL SELECT 'Monk familiar' AS `name`
		UNION ALL SELECT 'Mud Attack' AS `name`
		UNION ALL SELECT 'Mystic Repulse' AS `name`
		UNION ALL SELECT 'Nature''s Embrace' AS `name`
		UNION ALL SELECT 'Paladin familiar' AS `name`
		UNION ALL SELECT 'Paralyze Rune' AS `name`
		UNION ALL SELECT 'Physical Strike' AS `name`
		UNION ALL SELECT 'Poison Bomb Rune' AS `name`
		UNION ALL SELECT 'Poison Field Rune' AS `name`
		UNION ALL SELECT 'Poison Wall Rune' AS `name`
		UNION ALL SELECT 'Practise Fire Wave' AS `name`
		UNION ALL SELECT 'Practise Healing' AS `name`
		UNION ALL SELECT 'Protect Party' AS `name`
		UNION ALL SELECT 'Protector' AS `name`
		UNION ALL SELECT 'Rage of the Skies' AS `name`
		UNION ALL SELECT 'Recovery' AS `name`
		UNION ALL SELECT 'Restoration' AS `name`
		UNION ALL SELECT 'Restore Balance' AS `name`
		UNION ALL SELECT 'Salvation' AS `name`
		UNION ALL SELECT 'Sap Strength' AS `name`
		UNION ALL SELECT 'Scorch' AS `name`
		UNION ALL SELECT 'Sharpshooter' AS `name`
		UNION ALL SELECT 'Sorcerer familiar' AS `name`
		UNION ALL SELECT 'Soulfire Rune' AS `name`
		UNION ALL SELECT 'Spirit Mend' AS `name`
		UNION ALL SELECT 'Spiritual Outburst' AS `name`
		UNION ALL SELECT 'Stalagmite Rune' AS `name`
		UNION ALL SELECT 'Stone Shower Rune' AS `name`
		UNION ALL SELECT 'Strong Energy Strike' AS `name`
		UNION ALL SELECT 'Strong Ethereal Spear' AS `name`
		UNION ALL SELECT 'Strong Flame Strike' AS `name`
		UNION ALL SELECT 'Strong Haste' AS `name`
		UNION ALL SELECT 'Strong Ice Strike' AS `name`
		UNION ALL SELECT 'Strong Ice Wave' AS `name`
		UNION ALL SELECT 'Strong Terra Strike' AS `name`
		UNION ALL SELECT 'Sudden Death Rune' AS `name`
		UNION ALL SELECT 'Summon Creature' AS `name`
		UNION ALL SELECT 'Sweeping Takedown' AS `name`
		UNION ALL SELECT 'Swift Foot' AS `name`
		UNION ALL SELECT 'Swift Jab' AS `name`
		UNION ALL SELECT 'Terra Burst' AS `name`
		UNION ALL SELECT 'Terra Strike' AS `name`
		UNION ALL SELECT 'Terra Wave' AS `name`
		UNION ALL SELECT 'Thunderstorm Rune' AS `name`
		UNION ALL SELECT 'Tiger Clash' AS `name`
		UNION ALL SELECT 'Train Party' AS `name`
		UNION ALL SELECT 'Ultimate Energy Strike' AS `name`
		UNION ALL SELECT 'Ultimate Flame Strike' AS `name`
		UNION ALL SELECT 'Ultimate Healing' AS `name`
		UNION ALL SELECT 'Ultimate Healing Rune' AS `name`
		UNION ALL SELECT 'Ultimate Ice Strike' AS `name`
		UNION ALL SELECT 'Ultimate Light' AS `name`
		UNION ALL SELECT 'Ultimate Terra Strike' AS `name`
		UNION ALL SELECT 'Virtue of Harmony' AS `name`
		UNION ALL SELECT 'Virtue of Justice' AS `name`
		UNION ALL SELECT 'Virtue of Sustain' AS `name`
		UNION ALL SELECT 'Whirlwind Throw' AS `name`
		UNION ALL SELECT 'Wild Growth Rune' AS `name`
		UNION ALL SELECT 'Wound Cleansing' AS `name`
		UNION ALL SELECT 'Wrath of Nature' AS `name`
		) AS `s`
		WHERE `p`.`name` LIKE '% Sample';
	]])

	if not ok then
		logger.error("Failed to insert Sample player_spells rows.")
		return false
	end

	local resultId = db.storeQuery([[
		SELECT COUNT(*) AS `total`
		FROM `player_spells` AS `ps`
		INNER JOIN `players` AS `p` ON `p`.`id` = `ps`.`player_id`
		WHERE `p`.`name` LIKE '% Sample';
	]])
	if resultId then
		local total = Result.getNumber(resultId, "total")
		Result.free(resultId)
		logger.info("Sample characters now have {} player_spells rows (199 unique spell names)", total)
	end

	return true
end
