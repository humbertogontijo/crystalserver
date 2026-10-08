-- Auto-teach instant spells to * Sample characters (toggleLearnSpells is on).
SampleSpells = SampleSpells or {}

local SAMPLE_SUFFIX = " Sample"

function SampleSpells.isSampleCharacter(player)
	if not player then
		return false
	end
	local name = player:getName()
	return type(name) == "string" and name:sub(-#SAMPLE_SUFFIX) == SAMPLE_SUFFIX
end

local INSTANT_SPELL_NAMES = {
	"Animate Dead Rune",
	"Annihilation",
	"Apprentice's Strike",
	"Arrow Call",
	"Avalanche Rune",
	"Avatar of Balance",
	"Avatar of Light",
	"Avatar of Nature",
	"Avatar of Steel",
	"Avatar of Storm",
	"Balanced Brawl",
	"Berserk",
	"Blank Rune",
	"Blood Rage",
	"Bruise Bane",
	"Brutal Strike",
	"Buzz",
	"Cancel Invisibility",
	"Cancel Magic Shield",
	"Chained Penance",
	"Challenge",
	"Chameleon Rune",
	"Charge",
	"Chill Out",
	"Chivalrous Challenge",
	"Conjure Arrow",
	"Conjure Bolt",
	"Conjure Explosive Arrow",
	"Conjure Piercing Bolt",
	"Conjure Poisoned Arrow",
	"Conjure Power Bolt",
	"Conjure Royal Star",
	"Conjure Sniper Arrow",
	"Conjure Wand of Darkness",
	"Convince Creature Rune",
	"Creature Illusion",
	"Cure Bleeding",
	"Cure Burning",
	"Cure Curse",
	"Cure Electrification",
	"Cure Poison",
	"Cure Poison Rune",
	"Curse",
	"Death Strike",
	"Destroy Field Rune",
	"Devastating Knockout",
	"Disintegrate Rune",
	"Divine Caldera",
	"Divine Dazzle",
	"Divine Empowerment",
	"Divine Grenade",
	"Divine Healing",
	"Divine Missile",
	"Double Jab",
	"Druid familiar",
	"Electrify",
	"Enchant Party",
	"Enchant Spear",
	"Enchant Staff",
	"Energy Beam",
	"Energy Bomb Rune",
	"Energy Field Rune",
	"Energy Strike",
	"Energy Wall Rune",
	"Energy Wave",
	"Enlighten Party",
	"Envenom",
	"Eternal Winter",
	"Ethereal Spear",
	"Executioner's Throw",
	"Explosion Rune",
	"Expose Weakness",
	"Fair Wound Cleansing",
	"Fierce Berserk",
	"Find Fiend",
	"Find Person",
	"Fire Bomb Rune",
	"Fire Field Rune",
	"Fire Wall Rune",
	"Fire Wave",
	"Fireball Rune",
	"Flame Strike",
	"Flurry of Blows",
	"Focus Harmony",
	"Focus Serenity",
	"Food",
	"Forceful Uppercut",
	"Front Sweep",
	"Great Death Beam",
	"Great Energy Beam",
	"Great Fire Wave",
	"Great Fireball Rune",
	"Great Light",
	"Greater Flurry of Blows",
	"Greater Tiger Clash",
	"Groundshaker",
	"Haste",
	"Heal Friend",
	"Heal Malice",
	"Heal Monster",
	"Heal Monster 9x9",
	"Heal Party",
	"Heavy Magic Missile Rune",
	"Hell's Core",
	"Holy Flash",
	"Holy Missile Rune",
	"House Door List",
	"House Guest List",
	"House Kick",
	"House Subowner List",
	"Ice Burst",
	"Ice Strike",
	"Ice Wave",
	"Icicle Rune",
	"Ignite",
	"Inflict Wound",
	"Intense Healing",
	"Intense Healing Rune",
	"Intense Recovery",
	"Intense Wound Cleansing",
	"Invisibility",
	"Knight familiar",
	"Lesser Ethereal Spear",
	"Lesser Front Sweep",
	"Levitate",
	"Light",
	"Light Healing",
	"Light Magic Missile Rune",
	"Light Stone Shower Rune",
	"Lightest Magic Missile",
	"Lightest Missile Rune",
	"Lightning",
	"Magic Patch",
	"Magic Rope",
	"Magic Shield",
	"Magic Wall Rune",
	"Mass Healing",
	"Mass Spirit Mend",
	"Mentor Other",
	"Monk familiar",
	"Mud Attack",
	"Mystic Repulse",
	"Nature's Embrace",
	"Paladin familiar",
	"Paralyze Rune",
	"Physical Strike",
	"Poison Bomb Rune",
	"Poison Field Rune",
	"Poison Wall Rune",
	"Practise Fire Wave",
	"Practise Healing",
	"Protect Party",
	"Protector",
	"Rage of the Skies",
	"Recovery",
	"Restoration",
	"Restore Balance",
	"Salvation",
	"Sap Strength",
	"Scorch",
	"Sharpshooter",
	"Sorcerer familiar",
	"Soulfire Rune",
	"Spirit Mend",
	"Spiritual Outburst",
	"Stalagmite Rune",
	"Stone Shower Rune",
	"Strong Energy Strike",
	"Strong Ethereal Spear",
	"Strong Flame Strike",
	"Strong Haste",
	"Strong Ice Strike",
	"Strong Ice Wave",
	"Strong Terra Strike",
	"Sudden Death Rune",
	"Summon Creature",
	"Sweeping Takedown",
	"Swift Foot",
	"Swift Jab",
	"Terra Burst",
	"Terra Strike",
	"Terra Wave",
	"Thunderstorm Rune",
	"Tiger Clash",
	"Train Party",
	"Ultimate Energy Strike",
	"Ultimate Flame Strike",
	"Ultimate Healing",
	"Ultimate Healing Rune",
	"Ultimate Ice Strike",
	"Ultimate Light",
	"Ultimate Terra Strike",
	"Virtue of Harmony",
	"Virtue of Justice",
	"Virtue of Sustain",
	"Whirlwind Throw",
	"Wild Growth Rune",
	"Wound Cleansing",
	"Wrath of Nature",
}

--- Teach every instant spell + ensure premium for Sample characters.
function SampleSpells.ensure(player)
	if not SampleSpells.isSampleCharacter(player) then
		return 0
	end
	local taught = 0
	for _, spellName in ipairs(INSTANT_SPELL_NAMES) do
		if not player:hasLearnedSpell(spellName) then
			player:learnSpell(spellName)
			taught = taught + 1
		end
	end
	-- Premium-gated strikes (Energy Strike, etc.).
	if not player:isPremium() then
		player:addPremiumDays(365)
	end
	return taught
end

--- Before casting automation words, make sure the Sample knows that spell.
function SampleSpells.ensureWords(player, words)
	if not SampleSpells.isSampleCharacter(player) or type(words) ~= "string" or words == "" then
		return
	end
	local ok, spell = pcall(Spell, words)
	if not ok or not spell then
		return
	end
	local name = spell:name()
	if type(name) == "string" and name ~= "" and not player:hasLearnedSpell(name) then
		player:learnSpell(name)
	end
end
