CombatAutomationStore = CombatAutomationStore or {}

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

function CombatAutomationStore.sanitize(raw, player)
	local slots = {}
	local source = {}
	local stance = "melee"
	if ExpeditionConfig and ExpeditionConfig.stanceForPlayer then
		stance = ExpeditionConfig.stanceForPlayer(player) or "melee"
	elseif CombatAutomationCatalog and CombatAutomationCatalog.baseVocationKey then
		local key = CombatAutomationCatalog.baseVocationKey(player)
		if key == "paladin" then
			stance = "close"
		elseif key == "sorcerer" or key == "druid" then
			stance = "ranged"
		else
			stance = "melee"
		end
	end
	local autoTarget = {
		enabled = false,
		stance = stance,
		rangedDistance = (ExpeditionConfig and ExpeditionConfig.RANGED_DISTANCE_DEFAULT) or 4,
	}
	local ammoTypeId = 0
	if type(raw) == "table" then
		if type(raw.autoTarget) == "table" then
			autoTarget.enabled = raw.autoTarget.enabled == true
			local rawStance = raw.autoTarget.stance
			local rawRd = raw.autoTarget.rangedDistance
			if ExpeditionConfig and ExpeditionConfig.normalizeStanceForPlayer then
				autoTarget.stance, autoTarget.rangedDistance = ExpeditionConfig.normalizeStanceForPlayer(
					player,
					rawStance or stance,
					rawRd
				)
			else
				local role = rawStance or stance
				if role ~= "melee" and role ~= "close" and role ~= "ranged" then
					role = stance
				end
				autoTarget.stance = role
				if role == "ranged" then
					local rd = tonumber(rawRd)
					if ExpeditionConfig and ExpeditionConfig.normalizeRangedDistance then
						autoTarget.rangedDistance = ExpeditionConfig.normalizeRangedDistance(rd)
					elseif rd == 3 then
						autoTarget.rangedDistance = 3
					else
						autoTarget.rangedDistance = 4
					end
				end
			end
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
	-- Prefer first enabled ammo slot over legacy top-level field.
	for _, slot in ipairs(slots) do
		if slot.kind == "ammo" and slot.enabled ~= false then
			local id = math.floor(tonumber(slot.ammoTypeId) or 0)
			if id > 0 then
				ammoTypeId = id
				break
			end
		end
	end
	return { slots = slots, autoTarget = autoTarget, ammoTypeId = ammoTypeId }
end

local function defaultAutoTarget()
	return {
		enabled = false,
		stance = "melee",
		rangedDistance = (ExpeditionConfig and ExpeditionConfig.RANGED_DISTANCE_DEFAULT) or 4,
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
	kv:set(
		CombatAutomationConfig.KV_KEY,
		CombatAutomationJson.encode({
			slots = payload.slots or {},
			autoTarget = payload.autoTarget or defaultAutoTarget(),
			ammoTypeId = math.floor(tonumber(payload.ammoTypeId) or 0),
		})
	)
	-- Drop legacy key after successful write so we don't keep two sources of truth.
	if kv.remove then
		pcall(function()
			kv:remove(CombatAutomationConfig.KV_LEGACY_KEY)
		end)
	end
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
		raw = kv:get(CombatAutomationConfig.KV_LEGACY_KEY)
		if type(raw) == "string" and raw ~= "" then
			local migrated = CombatAutomationStore.sanitize(CombatAutomationJson.decode(raw), player)
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
	return CombatAutomationStore.sanitize(CombatAutomationJson.decode(raw), player)
end

function CombatAutomationStore.applyToRuntime(player, config)
	local state = CombatAutomation.getState(player)
	state.config = config or { slots = {}, autoTarget = defaultAutoTarget(), ammoTypeId = 0 }
	if ExpeditionManager and ExpeditionManager.getSessionByPlayer then
		local session = ExpeditionManager.getSessionByPlayer(player)
		if session then
			local pid = player:getId()
			local slots = state.config.slots or {}
			local ammoTypeId = math.floor(tonumber(state.config.ammoTypeId) or 0)
			local at = state.config.autoTarget or {}
			-- Keep each member's loadout; do not clobber the shared host field with companions.
			session.memberAutomation = session.memberAutomation or {}
			session.memberAutomation[pid] = {
				slots = slots,
				ammoTypeId = ammoTypeId,
				autoTarget = at,
			}
			if pid == session.playerId then
				session.automation = {
					slots = slots,
					ammoTypeId = ammoTypeId,
					autoTarget = at,
				}
			end
			-- Live stance refresh for formation / creature-stance (mages may change rangedDistance).
			session.memberStance = session.memberStance or {}
			session.memberStance[pid] = at.stance
				or (ExpeditionConfig and ExpeditionConfig.stanceForPlayer and ExpeditionConfig.stanceForPlayer(player))
				or "melee"
			session.memberRangedDistance = session.memberRangedDistance or {}
			session.memberRangedDistance[pid] = tonumber(at.rangedDistance)
				or (ExpeditionConfig and ExpeditionConfig.RANGED_DISTANCE_DEFAULT)
				or 4
			if pid == session.playerId then
				session.stance = session.memberStance[pid]
			end
		end
	end
	CombatAutomation.refreshLoop(player)
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
		CombatAutomationProtocol.sendConfig(player, config)
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
