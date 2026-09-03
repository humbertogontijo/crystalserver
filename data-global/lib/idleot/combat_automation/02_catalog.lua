CombatAutomationCatalog = CombatAutomationCatalog or {}

local function lowerName(name)
	return tostring(name or ""):lower()
end

function CombatAutomationCatalog.playerVocationName(player)
	if not player then
		return ""
	end
	local vocation = player:getVocation()
	if not vocation then
		return ""
	end
	local ok, name = pcall(function()
		return vocation:getName()
	end)
	if ok and type(name) == "string" then
		return lowerName(name)
	end
	return ""
end

function CombatAutomationCatalog.playerLevel(player)
	if not player then
		return 1
	end
	return math.max(1, math.floor(player:getLevel() or 1))
end

local function vocationAllowed(allowed, vocationName)
	if type(allowed) ~= "table" or #allowed == 0 then
		return true
	end
	-- Fail closed: unknown vocation must not unlock every restricted spell/rune.
	if vocationName == "" then
		return false
	end
	for _, entry in ipairs(allowed) do
		if lowerName(entry) == vocationName then
			return true
		end
	end
	return false
end

function CombatAutomationCatalog.spellAllowedForPlayer(spellId, player)
	local id = tostring(spellId or ""):lower():gsub("%s+", "_")
	local words = CombatAutomationConfig.SpellWordsById[id]
	if not words or not CombatAutomationConfig.AllowedSpellWords[words] then
		return false, nil
	end
	local minLevel = CombatAutomationConfig.SpellMinLevelById[id] or 1
	if CombatAutomationCatalog.playerLevel(player) < minLevel then
		return false, nil
	end
	local allowed = CombatAutomationConfig.SpellVocationsById[id]
	if not vocationAllowed(allowed, CombatAutomationCatalog.playerVocationName(player)) then
		return false, nil
	end
	return true, words
end

function CombatAutomationCatalog.runeAllowedForPlayer(typeId, player)
	local id = math.floor(tonumber(typeId) or 0)
	if id <= 0 or not CombatAutomationConfig.AllowedRunes[id] then
		return false
	end
	local minLevel = CombatAutomationConfig.RuneMinLevelByTypeId[id] or 1
	if CombatAutomationCatalog.playerLevel(player) < minLevel then
		return false
	end
	local allowed = CombatAutomationConfig.RuneVocationsByTypeId[id]
	return vocationAllowed(allowed, CombatAutomationCatalog.playerVocationName(player))
end

function CombatAutomationCatalog.potionAllowedForPlayer(typeId, player)
	local id = math.floor(tonumber(typeId) or 0)
	local effect = CombatAutomationConfig.PotionEffects[id]
	if not effect then
		return false
	end
	local minLevel = effect.minLevel or 1
	if CombatAutomationCatalog.playerLevel(player) < minLevel then
		return false
	end
	local allowed = effect.vocations
	return vocationAllowed(allowed, CombatAutomationCatalog.playerVocationName(player))
end

local function isPaladinVocation(vocationName)
	return vocationName == "paladin" or vocationName == "royal paladin"
end

function CombatAutomationCatalog.isPaladin(player)
	return isPaladinVocation(CombatAutomationCatalog.playerVocationName(player))
end

--- Map AllowedAmmo.kind → engine Ammo_t (AMMO_ARROW / AMMO_BOLT).
function CombatAutomationCatalog.ammoKindToType(kind)
	if kind == "arrow" then
		return AMMO_ARROW
	end
	if kind == "bolt" then
		return AMMO_BOLT
	end
	return AMMO_NONE
end

function CombatAutomationCatalog.ammoKindFromType(ammoType)
	if ammoType == AMMO_ARROW then
		return "arrow"
	end
	if ammoType == AMMO_BOLT then
		return "bolt"
	end
	return nil
end

--- Ammo type required by the player's equipped distance weapon (bow→arrow, crossbow→bolt).
function CombatAutomationCatalog.equippedWeaponAmmoKind(player)
	if not player then
		return nil
	end
	local weapon = player:getSlotItem(CONST_SLOT_LEFT)
	if not weapon then
		weapon = player:getSlotItem(CONST_SLOT_RIGHT)
	end
	if not weapon then
		return nil
	end
	local it = ItemType(weapon:getId())
	if not it or it:getWeaponType() ~= WEAPON_DISTANCE then
		return nil
	end
	return CombatAutomationCatalog.ammoKindFromType(it:getAmmoType())
end

function CombatAutomationCatalog.ammoAllowedForPlayer(typeId, player)
	local id = math.floor(tonumber(typeId) or 0)
	local entry = CombatAutomationConfig.AllowedAmmo and CombatAutomationConfig.AllowedAmmo[id]
	if not entry then
		return false
	end
	if not CombatAutomationCatalog.isPaladin(player) then
		return false
	end
	local minLevel = entry.minLevel or 1
	if CombatAutomationCatalog.playerLevel(player) < minLevel then
		return false
	end
	return true
end

--- Resolve configured ammo for the equipped weapon. No silent default - caller must configure.
function CombatAutomationCatalog.resolveAmmoTypeId(player, configuredTypeId)
	local configured = math.floor(tonumber(configuredTypeId) or 0)
	local weaponKind = CombatAutomationCatalog.equippedWeaponAmmoKind(player)
	if not weaponKind then
		return 0, nil
	end
	if configured <= 0 or not CombatAutomationCatalog.ammoAllowedForPlayer(configured, player) then
		return 0, weaponKind
	end
	local entry = CombatAutomationConfig.AllowedAmmo[configured]
	if not entry or entry.kind ~= weaponKind then
		return 0, weaponKind
	end
	return configured, weaponKind
end

local BASE_VOCATION_ALIAS = {
	knight = "knight",
	["elite knight"] = "knight",
	paladin = "paladin",
	["royal paladin"] = "paladin",
	sorcerer = "sorcerer",
	["master sorcerer"] = "sorcerer",
	druid = "druid",
	["elder druid"] = "druid",
	monk = "monk",
	["exalted monk"] = "monk",
}

function CombatAutomationCatalog.baseVocationKey(player)
	if player and player.getVocation and VOCATION and VOCATION.BASE_ID then
		local vocation = player:getVocation()
		if vocation and vocation.getBaseId then
			local baseId = vocation:getBaseId()
			if baseId == VOCATION.BASE_ID.KNIGHT then
				return "knight"
			end
			if baseId == VOCATION.BASE_ID.PALADIN then
				return "paladin"
			end
			if baseId == VOCATION.BASE_ID.SORCERER then
				return "sorcerer"
			end
			if baseId == VOCATION.BASE_ID.DRUID then
				return "druid"
			end
			if VOCATION.BASE_ID.MONK and baseId == VOCATION.BASE_ID.MONK then
				return "monk"
			end
		end
	end
	return BASE_VOCATION_ALIAS[CombatAutomationCatalog.playerVocationName(player)] or ""
end

--- Unsanitized starter loadout for the player's vocation (level-8 kit).
function CombatAutomationCatalog.baseLoadoutRaw(player)
	local key = CombatAutomationCatalog.baseVocationKey(player)
	if key == "" then
		return nil
	end
	local byVoc = CombatAutomationConfig.BaseLoadoutByVocation
	local spec = type(byVoc) == "table" and byVoc[key] or nil
	if type(spec) ~= "table" then
		return nil
	end
	return spec
end
