-- Vocation Adjustment: a Master Sorcerer's stance conversion reshapes Electrify (element + impact EFFECT
-- + missile DISTANCEEFFECT):
--   Master of Flames -> fire,  effect 329, missile 4
--   Master of Decay  -> death, effect 330, missile 11
--   Master of Thunder / no stance -> base energy (CONST_ME_ENERGYAREA, CONST_ANI_ENERGY)

local function makeCondition()
	local condition = Condition(CONDITION_ENERGY)
	condition:setParameter(CONDITION_PARAM_DELAYED, 1)
	condition:addDamage(25, 3000, -45)
	return condition
end

local function createElectrifyCombat(combatType, effect, missile)
	local c = Combat()
	c:setParameter(COMBAT_PARAM_TYPE, combatType)
	c:setParameter(COMBAT_PARAM_EFFECT, effect)
	c:setParameter(COMBAT_PARAM_DISTANCEEFFECT, missile)
	c:addCondition(makeCondition())
	return c
end

local combat = createElectrifyCombat(COMBAT_ENERGYDAMAGE, CONST_ME_ENERGYAREA, CONST_ANI_ENERGY)
local combatFlames = createElectrifyCombat(COMBAT_FIREDAMAGE, 329, 4)
local combatDecay = createElectrifyCombat(COMBAT_DEATHDAMAGE, 330, 11)

local spell = Spell("instant")

function spell.onCastSpell(creature, var)
	local player = creature:getPlayer()
	if player then
		local element = player:resolveElementConversion(COMBAT_ENERGYDAMAGE)
		if element == COMBAT_FIREDAMAGE then
			return combatFlames:execute(creature, var)
		elseif element == COMBAT_DEATHDAMAGE then
			return combatDecay:execute(creature, var)
		end
	end
	return combat:execute(creature, var)
end

spell:group("attack")
spell:id(140)
spell:name("Electrify")
spell:words("utori vis")
spell:castSound(SOUND_EFFECT_TYPE_SPELL_OR_RUNE)
spell:impactSound(SOUND_EFFECT_TYPE_SPELL_ELECTRIFY)
spell:level(34)
spell:mana(30)
spell:basePower(120)
spell:isAggressive(true)
spell:range(3)
spell:needTarget(true)
spell:blockWalls(true)
spell:cooldown(30 * 1000)
spell:groupCooldown(2 * 1000)
spell:vocation("sorcerer;true", "master sorcerer;true")
spell:register()
