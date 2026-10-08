-- Replaces stock exeta amp res (same words): KnightChallenge targeting and durations.
local combat = Combat()
combat:setParameter(COMBAT_PARAM_CHAIN_EFFECT, CONST_ME_CHIVALRIOUS_CHALLENGE)

local MELEE_DURATION = 12000

-- Product: ranged monsters only, farthest from the knight first (pulls distant ones in).
function canChain(creature, target)
	return KnightChallenge.chainPriority(creature, target, { rangedOnly = true })
end

combat:setCallback(CALLBACK_PARAM_CHAINPICKER, "canChain")

function getChainValue(creature)
	return KnightChallenge.chainTargets(creature), KnightChallenge.CHAIN_DISTANCE, false
end

combat:setCallback(CALLBACK_PARAM_CHAINVALUE, "getChainValue")

function onChain(creature, target)
	local duration = MELEE_DURATION
	local player = creature:getPlayer()
	if creature and player then
		duration = duration + (player:getWheelSpellAdditionalDuration(KnightChallenge.WHEEL_SPELL) * 1000)
	end
	if target and target:isMonster() then
		doChallengeCreature(creature, target, KnightChallenge.CHALLENGE_DURATION_MS)
		target:changeTargetDistance(1, duration)
	end
	return true
end

combat:setCallback(CALLBACK_PARAM_TARGETCREATURE, "onChain")

local spell = Spell("instant")

function spell.onCastSpell(creature, variant)
	local spectators = Game.getSpectators(creature:getPosition(), false, false)
	for _, spectator in pairs(spectators) do
		if spectator:isMonster() then
			if spectator:getType():isRewardBoss() then
				creature:sendCancelMessage("You can't use this spell if there's a boss.")
				creature:getPosition():sendMagicEffect(CONST_ME_POFF)
				return false
			end
		end
	end

	if not combat:execute(creature, variant) then
		creature:sendCancelMessage("There are no ranged monsters.")
		creature:getPosition():sendMagicEffect(CONST_ME_POFF)
		return false
	end
	return true
end

spell:group("support")
spell:id(237)
spell:name("Chivalrous Challenge")
spell:words("exeta amp res")
spell:castSound(SOUND_EFFECT_TYPE_SPELL_CHIVALROUS_CHALLENGE)
spell:level(150)
spell:mana(80)
spell:isAggressive(false)
spell:isPremium(true)
spell:cooldown(2 * 1000)
spell:groupCooldown(2 * 1000)
spell:vocation("knight;true", "elite knight;true")

spell:register()
