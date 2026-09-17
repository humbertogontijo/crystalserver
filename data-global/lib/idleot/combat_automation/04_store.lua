CombatAutomationStore = CombatAutomationStore or {}

-- Attack-page loadout banks (mirrors client AttackPreset.COUNT).
local ATTACK_PRESET_COUNT = 3

local function sanitizeSlot(raw, index, player)
	if type(raw) ~= "table" then
		return nil
	end
	local kind = raw.kind
	if kind ~= "potion" and kind ~= "spell" and kind ~= "rune" and kind ~= "ammo" then
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

	local slot = {
		id = type(raw.id) == "string" and raw.id ~= "" and raw.id or ("slot_" .. tostring(index)),
		enabled = raw.enabled ~= false,
		kind = kind,
		triggerStat = triggerStat,
		triggerPercent = triggerPercent,
		monsterCount = math.max(1, math.min(9, math.floor(tonumber(raw.monsterCount) or 1))),
		monsterCountMode = raw.monsterCountMode == "exact" and "exact" or "minimum",
		priority = math.floor(tonumber(raw.priority) or index),
		castIfTrapped = raw.castIfTrapped == true,
		harmonyThreshold = math.max(0, math.min(5, math.floor(tonumber(raw.harmonyThreshold) or 0))),
	}

	if kind == "potion" then
		local typeId = math.floor(tonumber(raw.potionTypeId) or 0)
		if typeId <= 0 or not CombatAutomationCatalog.potionAllowedForPlayer(typeId, player) then
			return nil
		end
		slot.potionTypeId = typeId
		-- Potions use HP/Mana only (no Always).
		if slot.triggerStat == "always" then
			slot.triggerStat = "hp"
			if slot.triggerPercent >= 100 then
				slot.triggerPercent = 50
			end
		end
	elseif kind == "rune" then
		local typeId = math.floor(tonumber(raw.runeTypeId) or 0)
		if typeId <= 0 or not CombatAutomationCatalog.runeAllowedForPlayer(typeId, player) then
			return nil
		end
		slot.runeTypeId = typeId
		slot.triggerStat = "always"
		slot.triggerPercent = 100
	elseif kind == "ammo" then
		local typeId = math.floor(tonumber(raw.ammoTypeId) or 0)
		if typeId <= 0 or not CombatAutomationCatalog.ammoAllowedForPlayer(typeId, player) then
			return nil
		end
		slot.ammoTypeId = typeId
		slot.triggerStat = "always"
		slot.triggerPercent = 100
	else
		local spellId = tostring(raw.spellId or ""):lower():gsub("%s+", "_")
		local ok, words = CombatAutomationCatalog.spellAllowedForPlayer(spellId, player)
		if not ok or not words then
			return nil
		end
		slot.spellId = spellId
		slot.words = words
		local group = CombatAutomationConfig.SpellGroupById and CombatAutomationConfig.SpellGroupById[spellId]
		local lowerWords = tostring(words):lower()
		local isCripple = lowerWords == "exori kor tempo" or lowerWords == "exori moe tempo"
		local isHaste = lowerWords:find("utani", 1, true) ~= nil or lowerWords == "utamo tempo san"
		if group == "attack" or group == "stance" or isCripple then
			slot.triggerStat = "always"
			slot.triggerPercent = 100
		elseif group == "healing" then
			-- Healing is HP-threshold only.
			slot.triggerStat = "hp"
			if slot.triggerPercent >= 100 then
				slot.triggerPercent = 99
			end
		end
		if isHaste then
			slot.pzCast = raw.pzCast == true
		end
	end
	return slot
end

local function sanitizeAttackPresetEntries(entries, player)
	local out = {}
	if type(entries) ~= "table" then
		return out
	end
	for i, entry in ipairs(entries) do
		local slot = sanitizeSlot(entry, i, player)
		if slot then
			out[#out + 1] = slot
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
		local entries = sanitizeAttackPresetEntries(source[i], player)
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
		rangedDistance = CombatAutomationConfig.RANGED_DISTANCE_DEFAULT or 3,
		mode = CombatAutomationConfig.AUTO_TARGET_MODE_DEFAULT or "A",
	}
	local ammoTypeId = 0
	local forceSkillOrder = true
	local attackPresets = nil
	if type(raw) == "table" then
		forceSkillOrder = raw.forceSkillOrder ~= false
		if type(raw.autoTarget) == "table" then
			autoTarget.enabled = raw.autoTarget.enabled == true
			local rawStance = raw.autoTarget.stance
			local rawRd = raw.autoTarget.rangedDistance
			autoTarget.stance, autoTarget.rangedDistance = CombatAutomationConfig.normalizeStanceForPlayer(
				player,
				rawStance or stance,
				rawRd
			)
			autoTarget.mode = CombatAutomationConfig.normalizeAutoTargetMode(
				raw.autoTarget.mode or raw.autoTarget.sortMode
			)
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
	for i, entry in ipairs(source) do
		local slot = sanitizeSlot(entry, i, player)
		if slot then
			slots[#slots + 1] = slot
			if ammoTypeId == 0 and slot.kind == "ammo" and slot.enabled ~= false then
				ammoTypeId = math.floor(tonumber(slot.ammoTypeId) or 0)
			end
		end
	end
	table.sort(slots, function(a, b)
		if a.priority == b.priority then
			return tostring(a.id) < tostring(b.id)
		end
		return a.priority < b.priority
	end)
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
		forceSkillOrder = forceSkillOrder,
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
		rangedDistance = CombatAutomationConfig.RANGED_DISTANCE_DEFAULT or 3,
		mode = CombatAutomationConfig.AUTO_TARGET_MODE_DEFAULT or "A",
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
	local payload = config
		or { slots = {}, autoTarget = defaultAutoTarget(), ammoTypeId = 0, forceSkillOrder = true }
	local encoded = {
		slots = payload.slots or {},
		autoTarget = payload.autoTarget or defaultAutoTarget(),
		ammoTypeId = math.floor(tonumber(payload.ammoTypeId) or 0),
		forceSkillOrder = payload.forceSkillOrder ~= false,
	}
	if type(payload.attackPresets) == "table" then
		encoded.attackPresets = payload.attackPresets
	end
	kv:set(CombatAutomationConfig.KV_KEY, JsonParser.encode(encoded))
	if kv.remove then
		pcall(function()
			kv:remove(CombatAutomationConfig.KV_LEGACY_KEY)
		end)
	end
end

local function emptyConfig()
	return { slots = {}, autoTarget = defaultAutoTarget(), ammoTypeId = 0, forceSkillOrder = true }
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
		raw = kv:get(CombatAutomationConfig.KV_LEGACY_KEY)
		if type(raw) == "string" and raw ~= "" then
			local migrated = CombatAutomationStore.sanitize(JsonParser.decode(raw), player)
			CombatAutomationStore.persist(player, migrated)
			return migrated
		end
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
	local nextCfg = config
		or { slots = {}, autoTarget = defaultAutoTarget(), ammoTypeId = 0, forceSkillOrder = true }
	local nextAuto = nextCfg.autoTarget and nextCfg.autoTarget.enabled == true
	local autoResumed = nextAuto and not prevAuto and prevCfg ~= nil
	state.config = nextCfg
	if ExpeditionManager and ExpeditionManager.getSessionByPlayer then
		local session = ExpeditionManager.getSessionByPlayer(player)
		if session then
			if autoResumed and ExpeditionAI and ExpeditionAI.onAutoResumed then
				ExpeditionAI.onAutoResumed(player)
			elseif ExpeditionAI and ExpeditionAI.enablePersistence then
				ExpeditionAI.enablePersistence(player)
			end
			if CombatAutomationMovement and CombatAutomationMovement.onAutoResumed and autoResumed then
				CombatAutomationMovement.onAutoResumed(player)
			end
		elseif autoResumed and CombatAutomationMovement and CombatAutomationMovement.onAutoResumed then
			CombatAutomationMovement.onAutoResumed(player)
		end
	elseif autoResumed and CombatAutomationMovement and CombatAutomationMovement.onAutoResumed then
		CombatAutomationMovement.onAutoResumed(player)
	end
	CombatAutomation.ensureLoop(player)
end

function CombatAutomationStore.setConfig(player, raw)
	if not player then
		return nil
	end
	if SampleSpells and SampleSpells.ensure then
		SampleSpells.ensure(player)
	end
	local existing = CombatAutomationStore.getConfig(player)
	local config = CombatAutomationStore.sanitize(raw, player)
	-- Preserve auto-target when legacy expedition payloads only update slots.
	if type(raw) == "table" and raw.autoTarget == nil then
		config.autoTarget = existing.autoTarget or config.autoTarget
	end
	-- Preserve ammo when payloads omit it (slot-only updates).
	if type(raw) == "table" and raw.ammoTypeId == nil then
		local loadout = raw.loadout
		local loadoutHasAmmo = type(loadout) == "table" and loadout.ammoTypeId ~= nil
		if not loadoutHasAmmo then
			config.ammoTypeId = existing.ammoTypeId or config.ammoTypeId
		end
	end
	if type(raw) == "table" and raw.forceSkillOrder == nil then
		local loadout = raw.loadout
		if not (type(loadout) == "table" and loadout.forceSkillOrder ~= nil) then
			config.forceSkillOrder = existing.forceSkillOrder ~= false
		end
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
	if CombatAutomationProtocol and CombatAutomationProtocol.sendConfig then
		CombatAutomationProtocol.sendConfig(player, config, { includePresets = true })
	end
	-- Delayed resync: early login ticks can fire before the client has self/map,
	-- and deduped attackTarget syncs would then never paint the red square.
	local playerId = player:getId()
	addEvent(function()
		local p = Player(playerId)
		if p and CombatAutomation and CombatAutomation.resyncAttackTarget then
			CombatAutomation.resyncAttackTarget(p)
		end
	end, 1500)
end

function CombatAutomationStore.onLogout(player)
	CombatAutomation.stopLoop(player)
	CombatAutomation.clearState(player)
end
