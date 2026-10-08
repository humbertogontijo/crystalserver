CombatAutomationProtocol = CombatAutomationProtocol or {}

local send = IdleUtil.jsonSender(CombatAutomationConfig.OPCODE)

function CombatAutomationProtocol.sendConfig(player, config, opts)
	opts = opts or {}
	config = config or CombatAutomationStore.getConfig(player)
	local at = config.autoTarget
		or { enabled = false, stance = "melee", rangedDistance = 3 }
	local payload = {
		type = "automationConfig",
		guid = player and player.getGuid and player:getGuid() or 0,
		name = player and player.getName and player:getName() or nil,
		autoTarget = {
			enabled = at.enabled == true,
			stance = at.stance or "melee",
			rangedDistance = math.floor(tonumber(at.rangedDistance) or CombatAutomationConfig.RANGED_DISTANCE_DEFAULT),
			cavebot = at.cavebot == true,
		},
		ammoTypeId = math.floor(tonumber(config.ammoTypeId) or 0),
		strictSkillOrder = config.strictSkillOrder == true,
		loadout = {
			slots = config.slots or {},
			ammoTypeId = math.floor(tonumber(config.ammoTypeId) or 0),
		},
	}
	-- Only include presets on explicit get/login. Echoing them on every setAutomation
	-- made the client re-import mid-click and disconnect.
	if opts.includePresets and type(config.attackPresets) == "table" then
		payload.attackPresets = config.attackPresets
	end
	return send(player, payload)
end

function CombatAutomationProtocol.sendCast(player, payload)
	if not player or type(payload) ~= "table" then
		return false
	end
	return send(player, {
		type = "automationCast",
		slotId = tostring(payload.slotId or ""),
		kind = tostring(payload.kind or ""),
		words = tostring(payload.words or ""),
		label = tostring(payload.label or payload.words or ""),
		exhaustMs = math.max(0, math.floor(tonumber(payload.exhaustMs) or 0)),
	})
end

--- Slot readiness the client cannot see: "missing" (an equip slot's item is not in
--- the player's inventory, so the rule sits idle) or "ok". Sent on change only.
function CombatAutomationProtocol.sendSlotStatus(player, slotId, status)
	if not player then
		return false
	end
	return send(player, {
		type = "automationSlotStatus",
		slotId = tostring(slotId or ""),
		status = tostring(status or "ok"),
	})
end

--- Sync auto-target to the client (vanilla has no S→C set-attack opcode).
--- Same wire as expedition AI so the red attack square / battle highlight update.
function CombatAutomationProtocol.sendAttackTarget(player, creatureId)
	local id = 0
	if creatureId and creatureId > 0 then
		id = creatureId
	end
	return send(player, {
		type = "attackTarget",
		creatureId = id,
	})
end

local function wireLoadoutFromMsg(msg)
	if type(msg) ~= "table" then
		return {
			slots = {},
			autoTarget = { enabled = false, stance = "melee", rangedDistance = 3 },
			ammoTypeId = 0,
		}
	end
	local ammoTypeId = msg.ammoTypeId
	local loadout = msg.loadout
	local strictSkillOrder = msg.strictSkillOrder
	local attackPresets = msg.attackPresets or msg.presets
	if type(loadout) == "table" then
		if ammoTypeId == nil then
			ammoTypeId = loadout.ammoTypeId
		end
		if strictSkillOrder == nil then
			strictSkillOrder = loadout.strictSkillOrder
		end
		if attackPresets == nil then
			attackPresets = loadout.attackPresets or loadout.presets
		end
		return {
			slots = loadout.slots or loadout,
			autoTarget = msg.autoTarget,
			ammoTypeId = ammoTypeId,
			strictSkillOrder = strictSkillOrder,
			attackPresets = attackPresets,
		}
	end
	if type(msg.slots) == "table" then
		return {
			slots = msg.slots,
			autoTarget = msg.autoTarget,
			ammoTypeId = ammoTypeId,
			strictSkillOrder = strictSkillOrder,
			attackPresets = attackPresets,
		}
	end
	return {
		slots = {},
		autoTarget = msg.autoTarget,
		ammoTypeId = ammoTypeId,
		strictSkillOrder = strictSkillOrder,
		attackPresets = attackPresets,
	}
end

--- Handle automation-related actions on opcode 113. Returns true if consumed.
function CombatAutomationProtocol.handleAction(player, msg)
	if not player or type(msg) ~= "table" then
		return false
	end
	if CavebotProtocol and CavebotProtocol.handleAction(player, msg) then
		return true
	end
	local action = msg.action
	if action == "getAutomation" then
		local config = CombatAutomationStore.getConfig(player)
		CombatAutomationProtocol.sendConfig(player, config, { includePresets = true })
		CombatAutomation.resetEquipStatus(player)
		-- Client is ready (map/self loaded); force-paint the current server target.
		CombatAutomation.resyncAttackTarget(player)
		if CavebotProtocol then
			CavebotProtocol.sendState(player, true)
		end
		return true
	end
	if action == "setAutomation" or action == "setBotConfig" then
		local config = CombatAutomationStore.setConfig(player, wireLoadoutFromMsg(msg))
		-- Do not echo attackPresets; client already has the bank it just pushed.
		CombatAutomationProtocol.sendConfig(player, config, { includePresets = false })
		CombatAutomation.resetEquipStatus(player)
		CombatAutomation.resyncAttackTarget(player)
		return true
	end
	if action == "setAttackPresets" then
		logger.info("[CombatAutomation] setAttackPresets from {}", player:getName())
		local existing = CombatAutomationStore.getConfig(player)
		local presets = CombatAutomationStore.sanitizeAttackPresets(msg.attackPresets or msg.presets, player)
		if presets then
			existing.attackPresets = presets
			CombatAutomationStore.persist(player, existing)
			if CombatAutomationStore.applyToRuntime then
				CombatAutomationStore.applyToRuntime(player, existing)
			end
		end
		-- Tiny ack only — never re-send full automationConfig.
		send(player, { type = "attackPresetsSaved", ok = presets ~= nil })
		return true
	end
	return false
end
