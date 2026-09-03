-- IdleOT custom migration (was numbered core *.product).
local m = Migration("20240830000004_sample_spells")
function m:onExecute()
	logger.info("Updating database to version 59 (teach all instant spells to Sample characters)")

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
			SELECT 'animate dead rune' AS `name`
		UNION ALL SELECT 'annihilation' AS `name`
		UNION ALL SELECT 'apprentice''s strike' AS `name`
		UNION ALL SELECT 'arrow call' AS `name`
		UNION ALL SELECT 'avalanche rune' AS `name`
		UNION ALL SELECT 'avatar of balance' AS `name`
		UNION ALL SELECT 'avatar of light' AS `name`
		UNION ALL SELECT 'avatar of nature' AS `name`
		UNION ALL SELECT 'avatar of steel' AS `name`
		UNION ALL SELECT 'avatar of storm' AS `name`
		UNION ALL SELECT 'balanced brawl' AS `name`
		UNION ALL SELECT 'berserk' AS `name`
		UNION ALL SELECT 'blank rune' AS `name`
		UNION ALL SELECT 'blood rage' AS `name`
		UNION ALL SELECT 'bruise bane' AS `name`
		UNION ALL SELECT 'brutal strike' AS `name`
		UNION ALL SELECT 'buzz' AS `name`
		UNION ALL SELECT 'cancel invisibility' AS `name`
		UNION ALL SELECT 'cancel magic shield' AS `name`
		UNION ALL SELECT 'chained penance' AS `name`
		UNION ALL SELECT 'challenge' AS `name`
		UNION ALL SELECT 'chameleon rune' AS `name`
		UNION ALL SELECT 'charge' AS `name`
		UNION ALL SELECT 'chill out' AS `name`
		UNION ALL SELECT 'chivalrous challenge' AS `name`
		UNION ALL SELECT 'conjure arrow' AS `name`
		UNION ALL SELECT 'conjure bolt' AS `name`
		UNION ALL SELECT 'conjure explosive arrow' AS `name`
		UNION ALL SELECT 'conjure piercing bolt' AS `name`
		UNION ALL SELECT 'conjure poisoned arrow' AS `name`
		UNION ALL SELECT 'conjure power bolt' AS `name`
		UNION ALL SELECT 'conjure royal star' AS `name`
		UNION ALL SELECT 'conjure sniper arrow' AS `name`
		UNION ALL SELECT 'conjure wand of darkness' AS `name`
		UNION ALL SELECT 'convince creature rune' AS `name`
		UNION ALL SELECT 'creature illusion' AS `name`
		UNION ALL SELECT 'cure bleeding' AS `name`
		UNION ALL SELECT 'cure burning' AS `name`
		UNION ALL SELECT 'cure curse' AS `name`
		UNION ALL SELECT 'cure electrification' AS `name`
		UNION ALL SELECT 'cure poison' AS `name`
		UNION ALL SELECT 'cure poison rune' AS `name`
		UNION ALL SELECT 'curse' AS `name`
		UNION ALL SELECT 'death strike' AS `name`
		UNION ALL SELECT 'destroy field rune' AS `name`
		UNION ALL SELECT 'devastating knockout' AS `name`
		UNION ALL SELECT 'disintegrate rune' AS `name`
		UNION ALL SELECT 'divine caldera' AS `name`
		UNION ALL SELECT 'divine dazzle' AS `name`
		UNION ALL SELECT 'divine empowerment' AS `name`
		UNION ALL SELECT 'divine grenade' AS `name`
		UNION ALL SELECT 'divine healing' AS `name`
		UNION ALL SELECT 'divine missile' AS `name`
		UNION ALL SELECT 'double jab' AS `name`
		UNION ALL SELECT 'druid familiar' AS `name`
		UNION ALL SELECT 'electrify' AS `name`
		UNION ALL SELECT 'enchant party' AS `name`
		UNION ALL SELECT 'enchant spear' AS `name`
		UNION ALL SELECT 'enchant staff' AS `name`
		UNION ALL SELECT 'energy beam' AS `name`
		UNION ALL SELECT 'energy bomb rune' AS `name`
		UNION ALL SELECT 'energy field rune' AS `name`
		UNION ALL SELECT 'energy strike' AS `name`
		UNION ALL SELECT 'energy wall rune' AS `name`
		UNION ALL SELECT 'energy wave' AS `name`
		UNION ALL SELECT 'enlighten party' AS `name`
		UNION ALL SELECT 'envenom' AS `name`
		UNION ALL SELECT 'eternal winter' AS `name`
		UNION ALL SELECT 'ethereal spear' AS `name`
		UNION ALL SELECT 'executioner''s throw' AS `name`
		UNION ALL SELECT 'explosion rune' AS `name`
		UNION ALL SELECT 'expose weakness' AS `name`
		UNION ALL SELECT 'fair wound cleansing' AS `name`
		UNION ALL SELECT 'fierce berserk' AS `name`
		UNION ALL SELECT 'find fiend' AS `name`
		UNION ALL SELECT 'find person' AS `name`
		UNION ALL SELECT 'fire bomb rune' AS `name`
		UNION ALL SELECT 'fire field rune' AS `name`
		UNION ALL SELECT 'fire wall rune' AS `name`
		UNION ALL SELECT 'fire wave' AS `name`
		UNION ALL SELECT 'fireball rune' AS `name`
		UNION ALL SELECT 'flame strike' AS `name`
		UNION ALL SELECT 'flurry of blows' AS `name`
		UNION ALL SELECT 'focus harmony' AS `name`
		UNION ALL SELECT 'focus serenity' AS `name`
		UNION ALL SELECT 'food' AS `name`
		UNION ALL SELECT 'forceful uppercut' AS `name`
		UNION ALL SELECT 'front sweep' AS `name`
		UNION ALL SELECT 'great death beam' AS `name`
		UNION ALL SELECT 'great energy beam' AS `name`
		UNION ALL SELECT 'great fire wave' AS `name`
		UNION ALL SELECT 'great fireball rune' AS `name`
		UNION ALL SELECT 'great light' AS `name`
		UNION ALL SELECT 'greater flurry of blows' AS `name`
		UNION ALL SELECT 'greater tiger clash' AS `name`
		UNION ALL SELECT 'groundshaker' AS `name`
		UNION ALL SELECT 'haste' AS `name`
		UNION ALL SELECT 'heal friend' AS `name`
		UNION ALL SELECT 'heal malice' AS `name`
		UNION ALL SELECT 'heal monster' AS `name`
		UNION ALL SELECT 'heal monster 9x9' AS `name`
		UNION ALL SELECT 'heal party' AS `name`
		UNION ALL SELECT 'heavy magic missile rune' AS `name`
		UNION ALL SELECT 'hell''s core' AS `name`
		UNION ALL SELECT 'holy flash' AS `name`
		UNION ALL SELECT 'holy missile rune' AS `name`
		UNION ALL SELECT 'house door list' AS `name`
		UNION ALL SELECT 'house guest list' AS `name`
		UNION ALL SELECT 'house kick' AS `name`
		UNION ALL SELECT 'house subowner list' AS `name`
		UNION ALL SELECT 'ice burst' AS `name`
		UNION ALL SELECT 'ice strike' AS `name`
		UNION ALL SELECT 'ice wave' AS `name`
		UNION ALL SELECT 'icicle rune' AS `name`
		UNION ALL SELECT 'ignite' AS `name`
		UNION ALL SELECT 'inflict wound' AS `name`
		UNION ALL SELECT 'intense healing' AS `name`
		UNION ALL SELECT 'intense healing rune' AS `name`
		UNION ALL SELECT 'intense recovery' AS `name`
		UNION ALL SELECT 'intense wound cleansing' AS `name`
		UNION ALL SELECT 'invisibility' AS `name`
		UNION ALL SELECT 'knight familiar' AS `name`
		UNION ALL SELECT 'lesser ethereal spear' AS `name`
		UNION ALL SELECT 'lesser front sweep' AS `name`
		UNION ALL SELECT 'levitate' AS `name`
		UNION ALL SELECT 'light' AS `name`
		UNION ALL SELECT 'light healing' AS `name`
		UNION ALL SELECT 'light magic missile rune' AS `name`
		UNION ALL SELECT 'light stone shower rune' AS `name`
		UNION ALL SELECT 'lightest magic missile' AS `name`
		UNION ALL SELECT 'lightest missile rune' AS `name`
		UNION ALL SELECT 'lightning' AS `name`
		UNION ALL SELECT 'magic patch' AS `name`
		UNION ALL SELECT 'magic rope' AS `name`
		UNION ALL SELECT 'magic shield' AS `name`
		UNION ALL SELECT 'magic wall rune' AS `name`
		UNION ALL SELECT 'mass healing' AS `name`
		UNION ALL SELECT 'mass spirit mend' AS `name`
		UNION ALL SELECT 'mentor other' AS `name`
		UNION ALL SELECT 'monk familiar' AS `name`
		UNION ALL SELECT 'mud attack' AS `name`
		UNION ALL SELECT 'mystic repulse' AS `name`
		UNION ALL SELECT 'nature''s embrace' AS `name`
		UNION ALL SELECT 'paladin familiar' AS `name`
		UNION ALL SELECT 'paralyze rune' AS `name`
		UNION ALL SELECT 'physical strike' AS `name`
		UNION ALL SELECT 'poison bomb rune' AS `name`
		UNION ALL SELECT 'poison field rune' AS `name`
		UNION ALL SELECT 'poison wall rune' AS `name`
		UNION ALL SELECT 'practise fire wave' AS `name`
		UNION ALL SELECT 'practise healing' AS `name`
		UNION ALL SELECT 'protect party' AS `name`
		UNION ALL SELECT 'protector' AS `name`
		UNION ALL SELECT 'rage of the skies' AS `name`
		UNION ALL SELECT 'recovery' AS `name`
		UNION ALL SELECT 'restoration' AS `name`
		UNION ALL SELECT 'restore balance' AS `name`
		UNION ALL SELECT 'salvation' AS `name`
		UNION ALL SELECT 'sap strength' AS `name`
		UNION ALL SELECT 'scorch' AS `name`
		UNION ALL SELECT 'sharpshooter' AS `name`
		UNION ALL SELECT 'sorcerer familiar' AS `name`
		UNION ALL SELECT 'soulfire rune' AS `name`
		UNION ALL SELECT 'spirit mend' AS `name`
		UNION ALL SELECT 'spiritual outburst' AS `name`
		UNION ALL SELECT 'stalagmite rune' AS `name`
		UNION ALL SELECT 'stone shower rune' AS `name`
		UNION ALL SELECT 'strong energy strike' AS `name`
		UNION ALL SELECT 'strong ethereal spear' AS `name`
		UNION ALL SELECT 'strong flame strike' AS `name`
		UNION ALL SELECT 'strong haste' AS `name`
		UNION ALL SELECT 'strong ice strike' AS `name`
		UNION ALL SELECT 'strong ice wave' AS `name`
		UNION ALL SELECT 'strong terra strike' AS `name`
		UNION ALL SELECT 'sudden death rune' AS `name`
		UNION ALL SELECT 'summon creature' AS `name`
		UNION ALL SELECT 'sweeping takedown' AS `name`
		UNION ALL SELECT 'swift foot' AS `name`
		UNION ALL SELECT 'swift jab' AS `name`
		UNION ALL SELECT 'terra burst' AS `name`
		UNION ALL SELECT 'terra strike' AS `name`
		UNION ALL SELECT 'terra wave' AS `name`
		UNION ALL SELECT 'thunderstorm rune' AS `name`
		UNION ALL SELECT 'tiger clash' AS `name`
		UNION ALL SELECT 'train party' AS `name`
		UNION ALL SELECT 'ultimate energy strike' AS `name`
		UNION ALL SELECT 'ultimate flame strike' AS `name`
		UNION ALL SELECT 'ultimate healing' AS `name`
		UNION ALL SELECT 'ultimate healing rune' AS `name`
		UNION ALL SELECT 'ultimate ice strike' AS `name`
		UNION ALL SELECT 'ultimate light' AS `name`
		UNION ALL SELECT 'ultimate terra strike' AS `name`
		UNION ALL SELECT 'virtue of harmony' AS `name`
		UNION ALL SELECT 'virtue of justice' AS `name`
		UNION ALL SELECT 'virtue of sustain' AS `name`
		UNION ALL SELECT 'whirlwind throw' AS `name`
		UNION ALL SELECT 'wild growth rune' AS `name`
		UNION ALL SELECT 'wound cleansing' AS `name`
		UNION ALL SELECT 'wrath of nature' AS `name`
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
m:register()
