local function formulaFunction(level, maglevel)
	local min = (calculateBaseDamageHealing(level)) + (maglevel * 5.5)
	local max = (calculateBaseDamageHealing(level)) + (maglevel * 9)
	return -min, -max
end

function onGetFormulaValues(player, level, maglevel)
	return formulaFunction(level, maglevel)
end

-- Vocation Adjustment: Beam Mastery fires two identical beams parallel to the main one (left + right),
-- each dealing 40/60/80% of the beam damage at Beam Mastery stage 1/2/3 (widens only; length stays 8 sqm).
function onGetFormulaValuesBeamFlank(player, level, maglevel)
	local stage = player:revelationStageWOD("Beam Mastery")
	local factor = (stage >= 3 and 0.80) or (stage >= 2 and 0.60) or (stage >= 1 and 0.40) or 0
	local min = ((calculateBaseDamageHealing(level)) + (maglevel * 5.5)) * factor
	local max = ((calculateBaseDamageHealing(level)) + (maglevel * 9)) * factor
	return -min, -max
end

-- Center row is {1, 3, 1}: directional areas anchor on the sqm in front of the caster, so the
-- first beam tile must include left/right parallels to match the full main-beam length.
local FLANK_AREA = { { 1, 0, 1 }, { 1, 0, 1 }, { 1, 0, 1 }, { 1, 0, 1 }, { 1, 0, 1 }, { 1, 0, 1 }, { 1, 0, 1 }, { 1, 3, 1 } }

local function createCombat(area, combatFunc)
	local c = Combat()
	c:setCallback(CALLBACK_PARAM_LEVELMAGICVALUE, combatFunc)
	c:setParameter(COMBAT_PARAM_TYPE, COMBAT_DEATHDAMAGE)
	c:setParameter(COMBAT_PARAM_EFFECT, CONST_ME_MORTAREA)
	c:setArea(createCombatArea(area))
	return c
end

local combat = createCombat(AREA_BEAM8, "onGetFormulaValues")
local flankCombat = createCombat(FLANK_AREA, "onGetFormulaValuesBeamFlank")

-- Vocation Adjustment: a Master Sorcerer's stance conversion reshapes the beam (element + impact effect).
-- Master of Flames -> fire (eff 334), Master of Thunder -> energy (eff 335), Decay/none -> base death.
-- Same formula/area per element, so retune the element on the main + flank Combat each cast.
local function applyStanceElement(player)
	local combatType, effect = COMBAT_DEATHDAMAGE, CONST_ME_MORTAREA
	local element = player:resolveElementConversion(COMBAT_DEATHDAMAGE)
	if element == COMBAT_FIREDAMAGE then
		combatType, effect = COMBAT_FIREDAMAGE, 334
	elseif element == COMBAT_ENERGYDAMAGE then
		combatType, effect = COMBAT_ENERGYDAMAGE, 335
	end
	for _, c in ipairs({ combat, flankCombat }) do
		c:setParameter(COMBAT_PARAM_TYPE, combatType)
		c:setParameter(COMBAT_PARAM_EFFECT, effect)
	end
end

local spell = Spell("instant")

function spell.onCastSpell(creature, var)
	if not creature or not creature:isPlayer() then
		return false
	end

	local player = creature:getPlayer()
	applyStanceElement(player)

	local result = combat:execute(creature, var)
	-- Beam Mastery: fire the parallel left + right beams (damage scaled inside the flank formula).
	if creature:revelationStageWOD("Beam Mastery") > 0 then
		flankCombat:execute(creature, var)
	end
	return result
end

spell:group("attack", "greatbeams")
spell:id(260)
spell:name("Great Death Beam")
spell:words("exevo max mort")
spell:level(66)
spell:mana(140)
spell:basePower(170)
spell:isPremium(false)
spell:needDirection(true)
spell:blockWalls(true)
spell:cooldown(10 * 1000)
spell:groupCooldown(2 * 1000, 6 * 1000)
spell:needLearn(false)
spell:vocation("sorcerer;true", "master sorcerer;true")
spell:register()
