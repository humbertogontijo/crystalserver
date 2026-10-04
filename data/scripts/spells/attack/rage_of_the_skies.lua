-- Vocation Adjustment: a Master Sorcerer's stance conversion reshapes Rage of the Skies (element + the
-- AoE magic EFFECT id):
--   Master of Flames -> fire,  effect 339
--   Master of Decay  -> death, effect 340
--   Master of Thunder / no stance -> base energy (CONST_ME_BIGCLOUDS)
local function rageFormula(level, maglevel)
	local min = (calculateBaseDamageHealing(level)) + (maglevel * 7)
	local max = (calculateBaseDamageHealing(level)) + (maglevel * 14)
	return -min, -max
end

-- Each combat needs its OWN callback name (won't let two combats share a callback name); all
-- three delegate to the same formula.
function onGetFormulaValues(player, level, maglevel, basePower)
	return rageFormula(level, maglevel)
end
function onGetFormulaValuesFlames(player, level, maglevel)
	return rageFormula(level, maglevel)
end
function onGetFormulaValuesDecay(player, level, maglevel)
	return rageFormula(level, maglevel)
end

local function createRageCombat(combatType, effect, callbackName)
	local c = Combat()
	c:setParameter(COMBAT_PARAM_TYPE, combatType)
	c:setParameter(COMBAT_PARAM_EFFECT, effect)
	c:setArea(createCombatArea(AREA_CIRCLE6X6))
	c:setCallback(CALLBACK_PARAM_LEVELMAGICVALUE, callbackName)
	return c
end

local combatEnergy = createRageCombat(COMBAT_ENERGYDAMAGE, CONST_ME_BIGCLOUDS, "onGetFormulaValues")
local combatFlames = createRageCombat(COMBAT_FIREDAMAGE, 339, "onGetFormulaValuesFlames")
local combatDecay = createRageCombat(COMBAT_DEATHDAMAGE, 340, "onGetFormulaValuesDecay")

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
	return combatEnergy:execute(creature, var)
end

spell:group("attack", "focus")
spell:id(119)
spell:name("Rage of the Skies")
spell:words("exevo gran mas vis")
spell:castSound(SOUND_EFFECT_TYPE_SPELL_RAGE_OF_THE_SKIES)
spell:level(55)
spell:mana(600)
spell:basePower(200)
spell:isSelfTarget(true)
spell:isPremium(true)
spell:cooldown(40 * 1000)
spell:groupCooldown(4 * 1000, 40 * 1000)
spell:vocation("sorcerer;true", "master sorcerer;true")
spell:register()
