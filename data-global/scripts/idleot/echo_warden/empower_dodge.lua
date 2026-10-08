-- ============================================================================
-- Echo Warden empower dodge — CIP-like dodge chance while empowered.
-- ============================================================================

local dodge = CreatureEvent("EchoWardenEmpowerDodge")

function dodge.onHealthChange(creature, attacker, primaryDamage, primaryType, secondaryDamage, secondaryType, origin)
	if not creature or not creature:isMonster() then
		return primaryDamage, primaryType, secondaryDamage, secondaryType
	end
	if creature:getStorageValue(EchoWarden.STORAGE_IS_EMPOWERED) ~= 1 then
		return primaryDamage, primaryType, secondaryDamage, secondaryType
	end
	if primaryDamage <= 0 and secondaryDamage <= 0 then
		return primaryDamage, primaryType, secondaryDamage, secondaryType
	end
	if math.random(1, 100) > EchoWarden.EMPOWER_DODGE_CHANCE then
		return primaryDamage, primaryType, secondaryDamage, secondaryType
	end
	creature:getPosition():sendMagicEffect(CONST_ME_DODGE)
	return 0, primaryType, 0, secondaryType
end

dodge:register()
