CombatAutomationStore = CombatAutomationStore or {}

-- Attack-page loadout banks (mirrors client AttackPreset.COUNT).
local ATTACK_PRESET_COUNT = 3
-- Bar slots (client SLOT_COUNT) and actions per multi-action slot (client MULTI_STEPS).
local SLOT_GROUPS = 14
local MULTI_STEPS = 3
CombatAutomationStore.SLOT_GROUPS = SLOT_GROUPS
CombatAutomationStore.MULTI_STEPS = MULTI_STEPS

-- Shared by every step of a multi-action slot.
local CONDITION_FIELDS = {
	"triggerStat",
	"triggerPercent",
	"monsterCount",
	"monsterCountMode",
	"castIfTrapped",
	"harmonyThreshold",
}

--- Per-kind trigger rules (potions never "always", attacks/runes/ammo always, healing HP only).
local function coerceCondition(slot)
	local kind = slot.kind
	local potionEffect = kind == "potion" and CombatAutomationConfig.PotionEffects[slot.potionTypeId]
	if potionEffect and potionEffect.manashield then
		-- Shield potions: Always (keep up) or Mana %, like utamo vita.
		if slot.triggerStat ~= "mana" then
			slot.triggerStat = "always"
			slot.triggerPercent = 100
		end
	elseif kind == "potion" then
		if slot.triggerStat == "always" then
			slot.triggerStat = "hp"
			if slot.triggerPercent >= 100 then
				slot.triggerPercent = 50
			end
		end
	elseif kind == "rune" or kind == "ammo" then
		slot.triggerStat = "always"
		slot.triggerPercent = 100
	elseif kind == "equip" then
		-- HP / mana only; below 100 so the release threshold stays reachable.
		if slot.triggerStat ~= "mana" then
			slot.triggerStat = "hp"
		end
		slot.triggerPercent = math.max(1, math.min(99, slot.triggerPercent))
	elseif kind == "spell" then
		local group = CombatAutomationConfig.SpellGroupById[slot.spellId]
		local lowerWords = tostring(slot.words or ""):lower()
		local isCripple = lowerWords == "exori kor tempo" or lowerWords == "exori moe tempo"
		if group == "attack" or group == "stance" or isCripple then
			slot.triggerStat = "always"
			slot.triggerPercent = 100
		elseif group == "healing" then
			slot.triggerStat = "hp"
			if slot.triggerPercent >= 100 then
				slot.triggerPercent = 99
			end
		end
	end
end

local function clampInt(value, low, high, fallback)
	local n = math.floor(tonumber(value) or fallback)
	if n < low then
		return low
	end
	if n > high then
		return high
	end
	return n
end

--- Bar slot + step.
local function slotPosition(raw)
	return clampInt(raw.group, 1, SLOT_GROUPS, 1), clampInt(raw.step, 1, MULTI_STEPS, 1)
end

local function sanitizeSlot(raw, player)
	if type(raw) ~= "table" then
		return nil
	end
	local kind = raw.kind
	if kind ~= "potion" and kind ~= "spell" and kind ~= "rune" and kind ~= "ammo" and kind ~= "equip" then
		return nil
	end
	local triggerStat = raw.triggerStat
	if type(raw.trigger) == "table" and raw.trigger.stat then
		triggerStat = raw.trigger.stat
	end
	if triggerStat ~= "hp" and triggerStat ~= "mana" and triggerStat ~= "always" then
		triggerStat = "hp"
	end
	local triggerPercent = tonumber(raw.triggerPercent)
	if type(raw.trigger) == "table" and raw.trigger.percent ~= nil then
		triggerPercent = tonumber(raw.trigger.percent)
	end
	triggerPercent = math.floor(triggerPercent or 0)
	if triggerPercent < 0 then
		triggerPercent = 0
	elseif triggerPercent > 100 then
		triggerPercent = 100
	end

	local group, step = slotPosition(raw)
	local slot = {
		id = "slot-" .. group .. "-" .. step,
		group = group,
		step = step,
		enabled = raw.enabled ~= false,
		kind = kind,
		triggerStat = triggerStat,
		triggerPercent = triggerPercent,
		monsterCount = math.max(1, math.min(9, math.floor(tonumber(raw.monsterCount) or 1))),
		monsterCountMode = raw.monsterCountMode == "exact" and "exact" or "minimum",
		priority = (group - 1) * MULTI_STEPS + step,
		castIfTrapped = raw.castIfTrapped == true,
		harmonyThreshold = math.max(0, math.min(5, math.floor(tonumber(raw.harmonyThreshold) or 0))),
	}

	if kind == "potion" then
		local typeId = math.floor(tonumber(raw.potionTypeId) or 0)
		if typeId <= 0 or not CombatAutomationCatalog.potionAllowedForPlayer(typeId, player) then
			return nil
		end
		slot.potionTypeId = typeId
	elseif kind == "rune" then
		local typeId = math.floor(tonumber(raw.runeTypeId) or 0)
		if typeId <= 0 or not CombatAutomationCatalog.runeAllowedForPlayer(typeId, player) then
			return nil
		end
		slot.runeTypeId = typeId
	elseif kind == "ammo" then
		local typeId = math.floor(tonumber(raw.ammoTypeId) or 0)
		if typeId <= 0 or not CombatAutomationCatalog.ammoAllowedForPlayer(typeId, player) then
			return nil
		end
		slot.ammoTypeId = typeId
	elseif kind == "equip" then
		local typeId = math.floor(tonumber(raw.equipTypeId) or 0)
		local entry = CombatAutomationConfig.EquipItems[typeId]
		if
			not entry
			or group ~= CombatAutomationConfig.EQUIP_GROUP
			or step ~= CombatAutomationConfig.EQUIP_STEP_BY_SLOT[entry.slot]
			or not CombatAutomationCatalog.equipAllowedForPlayer(typeId, player)
		then
			return nil
		end
		slot.equipTypeId = typeId
	else
		local spellId = tostring(raw.spellId or ""):lower():gsub("%s+", "_")
		local ok, words = CombatAutomationCatalog.spellAllowedForPlayer(spellId, player)
		if not ok or not words then
			return nil
		end
		slot.spellId = spellId
		slot.words = words
		local lowerWords = tostring(words):lower()
		if lowerWords:find("utani", 1, true) ~= nil or lowerWords == "utamo tempo san" then
			slot.pzCast = raw.pzCast == true
		end
	end
	coerceCondition(slot)
	if kind == "equip" then
		local margin = CombatAutomationConfig.EQUIP_RELEASE_MARGIN or 30
		slot.releasePercent = clampInt(raw.releasePercent, slot.triggerPercent + 1, 100, math.min(100, slot.triggerPercent + margin))
	end
	return slot
end

local function byGroupStep(a, b)
	if a.priority == b.priority then
		return tostring(a.id) < tostring(b.id)
	end
	return a.priority < b.priority
end

--- Support buffs, stances and ammo ignore the trigger, so they never define a group's condition.
local function carriesCondition(slot)
	if slot.kind == "ammo" then
		return false
	end
	if slot.kind ~= "spell" then
		return true
	end
	local group = CombatAutomationConfig.SpellGroupById[slot.spellId]
	return group ~= "support" and group ~= "stance"
end

--- Sanitize a raw slot list: drop invalid / duplicate (group, step) entries, sort by
--- (group, step), and give every step of a group the condition of its first step that
--- carries one (else its lowest step). Steps of a side group keep their own.
local function sanitizeSlotList(entries, player)
	local out = {}
	if type(entries) ~= "table" then
		return out
	end
	local taken = {}
	for _, entry in ipairs(entries) do
		local slot = sanitizeSlot(entry, player)
		if slot then
			local key = slot.group * 10 + slot.step
			if not taken[key] then
				taken[key] = true
				out[#out + 1] = slot
			end
		end
	end
	table.sort(out, byGroupStep)
	local sideGroups = CombatAutomationConfig.SIDE_GROUPS or {}
	local sources = {}
	for _, slot in ipairs(out) do
		local current = sources[slot.group]
		if not sideGroups[slot.group] and (not current or (not carriesCondition(current) and carriesCondition(slot))) then
			sources[slot.group] = slot
		end
	end
	for _, slot in ipairs(out) do
		local source = sources[slot.group]
		if source and source ~= slot then
			for _, field in ipairs(CONDITION_FIELDS) do
				slot[field] = source[field]
			end
			coerceCondition(slot)
		end
	end
	return out
end

--- Normalize attack-preset bank ({ index, seeded, presets = { {...}, ... } }).
function CombatAutomationStore.sanitizeAttackPresets(raw, player)
	if type(raw) ~= "table" then
		return nil
	end
	local source = raw.presets
	if type(source) ~= "table" then
		return nil
	end
	local presets = {}
	local hasAny = false
	for i = 1, ATTACK_PRESET_COUNT do
		local entries = sanitizeSlotList(source[i], player)
		presets[i] = entries
		if #entries > 0 then
			hasAny = true
		end
	end
	local index = math.floor(tonumber(raw.index) or 1)
	if index < 1 then
		index = 1
	elseif index > ATTACK_PRESET_COUNT then
		index = ATTACK_PRESET_COUNT
	end
	return {
		index = index,
		seeded = raw.seeded == true or hasAny,
		presets = presets,
	}
end

function CombatAutomationStore.sanitize(raw, player)
	local slots = {}
	local source = {}
	local stance = CombatAutomationConfig.stanceForPlayer(player) or "melee"
	local autoTarget = {
		enabled = false,
		stance = stance,
		rangedDistance = CombatAutomationConfig.RANGED_DISTANCE_DEFAULT,
		cavebot = false,
	}
	local ammoTypeId = 0
	local strictSkillOrder = false
	local attackPresets = nil
	if type(raw) == "table" then
		strictSkillOrder = raw.strictSkillOrder == true
		if type(raw.autoTarget) == "table" then
			autoTarget.enabled = raw.autoTarget.enabled == true
			autoTarget.cavebot = raw.autoTarget.cavebot == true
			autoTarget.stance, autoTarget.rangedDistance =
				CombatAutomationConfig.normalizeStanceForPlayer(player, raw.autoTarget.stance or stance)
		end
		local rawAmmo = math.floor(tonumber(raw.ammoTypeId) or 0)
		if rawAmmo > 0 and CombatAutomationCatalog.ammoAllowedForPlayer(rawAmmo, player) then
			ammoTypeId = rawAmmo
		end
		if type(raw.slots) == "table" then
			source = raw.slots
		elseif type(raw.loadout) == "table" and type(raw.loadout.slots) == "table" then
			source = raw.loadout.slots
			if ammoTypeId == 0 then
				local loadoutAmmo = math.floor(tonumber(raw.loadout.ammoTypeId) or 0)
				if loadoutAmmo > 0 and CombatAutomationCatalog.ammoAllowedForPlayer(loadoutAmmo, player) then
					ammoTypeId = loadoutAmmo
				end
			end
		else
			local looksArray = true
			for k, _ in pairs(raw) do
				if type(k) ~= "number" then
					looksArray = false
					break
				end
			end
			if looksArray then
				source = raw
			end
		end
		local rawPresets = raw.attackPresets or raw.presets
		if type(raw.loadout) == "table" and rawPresets == nil then
			rawPresets = raw.loadout.attackPresets or raw.loadout.presets
		end
		attackPresets = CombatAutomationStore.sanitizeAttackPresets(rawPresets, player)
	end
	slots = sanitizeSlotList(source, player)
	for _, slot in ipairs(slots) do
		if slot.kind == "ammo" and slot.enabled ~= false then
			local id = math.floor(tonumber(slot.ammoTypeId) or 0)
			if id > 0 then
				ammoTypeId = id
				break
			end
		end
	end
	local config = {
		slots = slots,
		autoTarget = autoTarget,
		ammoTypeId = ammoTypeId,
		strictSkillOrder = strictSkillOrder,
	}
	if attackPresets then
		config.attackPresets = attackPresets
	end
	return config
end

local function defaultAutoTarget()
	return {
		enabled = false,
		stance = "melee",
		rangedDistance = CombatAutomationConfig.RANGED_DISTANCE_DEFAULT,
		cavebot = false,
	}
end

function CombatAutomationStore.persist(player, config)
	if not player then
		return
	end
	local kv = player:kv()
	if not kv then
		return
	end
	local payload = config or { slots = {}, autoTarget = defaultAutoTarget(), ammoTypeId = 0 }
	local encoded = {
		slots = payload.slots or {},
		autoTarget = payload.autoTarget or defaultAutoTarget(),
		ammoTypeId = math.floor(tonumber(payload.ammoTypeId) or 0),
		strictSkillOrder = payload.strictSkillOrder == true,
	}
	if type(payload.attackPresets) == "table" then
		encoded.attackPresets = payload.attackPresets
	end
	kv:set(CombatAutomationConfig.KV_KEY, JsonParser.encode(encoded))
end

local function emptyConfig()
	return { slots = {}, autoTarget = defaultAutoTarget(), ammoTypeId = 0 }
end

local function seedBaseLoadout(player)
	local raw = CombatAutomationCatalog.baseLoadoutRaw(player)
	if type(raw) ~= "table" then
		return emptyConfig()
	end
	return CombatAutomationStore.sanitize(raw, player)
end

function CombatAutomationStore.load(player)
	if not player then
		return emptyConfig()
	end
	local kv = player:kv()
	if not kv then
		return emptyConfig()
	end
	local raw = kv:get(CombatAutomationConfig.KV_KEY)
	if type(raw) ~= "string" or raw == "" then
		local seeded = seedBaseLoadout(player)
		if #(seeded.slots or {}) > 0 then
			CombatAutomationStore.persist(player, seeded)
			return seeded
		end
		return emptyConfig()
	end
	return CombatAutomationStore.sanitize(JsonParser.decode(raw), player)
end

function CombatAutomationStore.applyToRuntime(player, config)
	local state = CombatAutomation.getState(player)
	local prevCfg = state.config
	local prevAuto = prevCfg and prevCfg.autoTarget and prevCfg.autoTarget.enabled == true
	local nextCfg = config or { slots = {}, autoTarget = defaultAutoTarget(), ammoTypeId = 0 }
	local nextAuto = nextCfg.autoTarget and nextCfg.autoTarget.enabled == true
	local autoResumed = nextAuto and not prevAuto and prevCfg ~= nil
	state.config = nextCfg
	local session = ExpeditionManager.getSessionByPlayer(player)
	if session then
		if autoResumed then
			ExpeditionAI.onAutoResumed(player)
		else
			ExpeditionAI.enablePersistence(player)
		end
	elseif autoResumed then
		CombatAutomationMovement.onAutoResumed(player)
	end
	CavebotStore.onConfigChanged(player)
end

function CombatAutomationStore.setConfig(player, raw)
	if not player then
		return nil
	end
	SampleSpells.ensure(player)
	local existing = CombatAutomationStore.getConfig(player)
	local config = CombatAutomationStore.sanitize(raw, player)
	-- Preserve auto-target when legacy expedition payloads only update slots.
	if type(raw) == "table" and raw.autoTarget == nil then
		config.autoTarget = existing.autoTarget or config.autoTarget
	elseif type(raw) == "table" and type(raw.autoTarget) == "table" and raw.autoTarget.cavebot == nil and existing.autoTarget then
		config.autoTarget.cavebot = existing.autoTarget.cavebot == true
	end
	CavebotStore.filterConfig(player, config, existing)
	-- Preserve ammo when payloads omit it (slot-only updates).
	if type(raw) == "table" and raw.ammoTypeId == nil then
		local loadout = raw.loadout
		local loadoutHasAmmo = type(loadout) == "table" and loadout.ammoTypeId ~= nil
		if not loadoutHasAmmo then
			config.ammoTypeId = existing.ammoTypeId or config.ammoTypeId
		end
	end
	if type(raw) == "table" and raw.strictSkillOrder == nil then
		config.strictSkillOrder = existing.strictSkillOrder == true
	end
	-- Preserve attack presets when payloads omit them (slot-only / legacy updates).
	if type(raw) == "table" then
		local rawPresets = raw.attackPresets or raw.presets
		if rawPresets == nil and type(raw.loadout) == "table" then
			rawPresets = raw.loadout.attackPresets or raw.loadout.presets
		end
		if rawPresets == nil then
			config.attackPresets = existing.attackPresets
		end
	end
	-- AUTO may be toggled off during expeditions (e.g. to tame). Attack slots and
	-- hunt AI honor autoTarget.enabled; heals/support/potions keep running.
	CombatAutomationStore.persist(player, config)
	CombatAutomationStore.applyToRuntime(player, config)
	return config
end

function CombatAutomationStore.getConfig(player)
	local state = CombatAutomation.getState(player)
	if state.config and type(state.config.slots) == "table" and (#state.config.slots > 0 or state.config._loaded) then
		return state.config
	end
	local config = CombatAutomationStore.load(player)
	config._loaded = true
	CombatAutomationStore.applyToRuntime(player, config)
	return config
end

function CombatAutomationStore.onLogin(player)
	if not player then
		return
	end
	local config = CombatAutomationStore.load(player)
	config._loaded = true
	CombatAutomationStore.applyToRuntime(player, config)
	CombatAutomationProtocol.sendConfig(player, config, { includePresets = true })
end

function CombatAutomationStore.onLogout(player)
	CombatAutomation.clearState(player)
end
