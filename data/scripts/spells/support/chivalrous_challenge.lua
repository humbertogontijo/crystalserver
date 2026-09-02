local combat = Combat()
combat:setParameter(COMBAT_PARAM_CHAIN_EFFECT, CONST_ME_CHIVALRIOUS_CHALLENGE)

-- Product: chain onto ranged types (vanilla) or any non-adjacent monster so
-- knights can pull distant melee packs; always challenge (aggro) like exeta res.
function canChain(creature, target)
	if not target:isMonster() then
		return false
	end
	if target:getType():isRewardBoss() then
		return false
	end
	if target:getMaster() ~= nil then
		return false
	end

	local origin = creature:getPosition()
	local tp = target:getPosition()
	if not origin or not tp or origin.z ~= tp.z then
		return false
	end

	local cheb = math.max(math.abs(tp.x - origin.x), math.abs(tp.y - origin.y))
	if target:getType():getTargetDistance() > 1 or cheb > 1 then
		return true
	end
	return false
end

combat:setCallback(CALLBACK_PARAM_CHAINPICKER, "canChain")

function getChainValue(creature)
	local targets = 4 -- Vocation Adjustment: +1 additional target (3 -> 4)
	local player = creature:getPlayer()
	if creature and player then
		targets = targets + player:getWheelSpellAdditionalTarget("Chivalrous Challenge")
	end
	return targets, 7, false
end

combat:setCallback(CALLBACK_PARAM_CHAINVALUE, "getChainValue")

function onChain(creature, target)
	local duration = 12000
	local player = creature:getPlayer()
	if creature and player then
		duration = duration + (player:getWheelSpellAdditionalDuration("Chivalrous Challenge") * 1000)
	end
	if target and target:isMonster() then
		-- Same aggro behavior as Challenge (exeta res).
		doChallengeCreature(creature, target, duration)
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
		creature:sendCancelMessage("There are no creatures in range.")
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
