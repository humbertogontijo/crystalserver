local combat = Combat()
combat:setParameter(COMBAT_PARAM_EFFECT, 288)
combat:setParameter(COMBAT_PARAM_AGGRESSIVE, false)

local spell = Spell("instant")

function spell.onCastSpell(creature, variant)
	local player = creature:getPlayer()
	if player and player:getStance() == STANCE_EXPOSE_WEAKNESS then
		player:setStance(STANCE_NONE)
		player:getPosition():sendMagicEffect(CONST_ME_POFF)
		return true
	end
	if player then
		player:setStance(STANCE_EXPOSE_WEAKNESS)
	end
	return combat:execute(creature, variant)
end

spell:name("Aura of Exposed Weakness")
spell:words("exori moe tempo")
spell:group("support", "crippling")
spell:vocation("master sorcerer;true")
spell:id(312)
spell:cooldown(30 * 1000)
spell:groupCooldown(2 * 1000, 30 * 1000)
spell:level(175)
spell:mana(1500)
spell:needLearn(false)
spell:isSelfTarget(true)
spell:isAggressive(false)
spell:isPremium(true)

spell:register()
