local combat = Combat()
combat:setParameter(COMBAT_PARAM_EFFECT, CONST_ME_MAGIC_BLUE)
combat:setArea(createCombatArea(AREA_SQUARE1X1))

function onTargetCreature(creature, target)
	return doChallengeCreature(creature, target)
end

combat:setCallback(CALLBACK_PARAM_TARGETCREATURE, "onTargetCreature")

-- Product: also chain-challenge distant monsters of any kind (white Chivalrous Challenge effect).
-- They keep their range; only when the knight has a free tile around him.
local chainCombat = Combat()
chainCombat:setParameter(COMBAT_PARAM_CHAIN_EFFECT, CustomEffects.CHIVALROUS_CHALLENGE_WHITE)

function challengeChainPicker(creature, target)
	return KnightChallenge.chainPriority(creature, target, { skipAdjacent = true })
end

chainCombat:setCallback(CALLBACK_PARAM_CHAINPICKER, "challengeChainPicker")

function challengeChainValue(creature)
	return KnightChallenge.chainTargets(creature), KnightChallenge.CHAIN_DISTANCE, false
end

chainCombat:setCallback(CALLBACK_PARAM_CHAINVALUE, "challengeChainValue")

function challengeChainTarget(creature, target)
	if target and target:isMonster() then
		doChallengeCreature(creature, target, KnightChallenge.CHALLENGE_DURATION_MS)
	end
	return true
end

chainCombat:setCallback(CALLBACK_PARAM_TARGETCREATURE, "challengeChainTarget")

local spell = Spell("instant")

function spell.onCastSpell(creature, variant)
	local result = combat:execute(creature, variant)
	if KnightChallenge.hasRoomAround(creature) then
		chainCombat:execute(creature, variant)
	end
	return result
end

spell:name("Challenge")
spell:words("exeta res")
spell:group("support")
spell:vocation("elite knight;true")
spell:castSound(SOUND_EFFECT_TYPE_SPELL_CHALLENGE)
spell:id(93)
spell:cooldown(2 * 1000)
spell:groupCooldown(2 * 1000)
spell:level(20)
spell:mana(30)
spell:isAggressive(false)
spell:isPremium(true)

spell:register()
