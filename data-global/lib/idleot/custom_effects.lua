-- Product virtual effect ids. OTClient draws them as a CIP base effect plus a shader
-- (mods/custom/game_custom_effects); keep ids in sync with that registry.
CustomEffects = CustomEffects or {}

-- Magic effects (position:sendMagicEffect) — client EFFECT_VARIANTS.
CustomEffects.CHIVALROUS_CHALLENGE_WHITE = 1000
-- Instance-teleport arrival: CIP POI found beam (195) tinted like the channel aura.
CustomEffects.IT_ARRIVAL_HOMETOWN = 1001
CustomEffects.IT_ARRIVAL_HOME = 1002
CustomEffects.IT_ARRIVAL_EXPEDITION = 1003

-- Creature attached effects (creature:attachEffectById) — client ATTACHED_EFFECTS.
-- Instance-teleport channel aura: CIP POI idle marker (193) per kind tint.
CustomEffects.IT_AURA_HOMETOWN = 1101
CustomEffects.IT_AURA_HOME = 1102
CustomEffects.IT_AURA_EXPEDITION = 1103

-- warnUnsafeScripts only whitelists appearances.dat ids; virtual ids must opt in.
if Game.registerMagicEffect then
	for _, effectId in ipairs({
		CustomEffects.CHIVALROUS_CHALLENGE_WHITE,
		CustomEffects.IT_ARRIVAL_HOMETOWN,
		CustomEffects.IT_ARRIVAL_HOME,
		CustomEffects.IT_ARRIVAL_EXPEDITION,
	}) do
		Game.registerMagicEffect(effectId)
	end
end
