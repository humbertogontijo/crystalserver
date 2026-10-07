-- Per-instance-kind PvP mode (stock world types) and death rules.
-- Combat, skulls and secure mode stay stock; the engine resolves the world type
-- per instance (Game.getWorldType(instanceId)). The main open world (instance 0,
-- cities, settlements, hub) uses the world's own type from `worlds.type`.
InstancePvp = InstancePvp or {}

-- worldType: stock world type for instances of this kind (nil = main world type).
-- deathPenalty = false: lethal damage knocks the player out (soft death) and they
-- respawn in place after respawnSec, with no loot or skill loss.
InstancePvp.KINDS = {
	world = {},
	lobby = { worldType = WORLDTYPE_OPTIONAL },
	hunt = { worldType = WORLDTYPE_OPTIONAL },
	raid = { worldType = WORLDTYPE_OPTIONAL },
	soulpit = { worldType = WORLDTYPE_OPTIONAL },
	arena = { worldType = WORLDTYPE_OPTIONAL },
	worldboss = { worldType = WORLDTYPE_OPEN, deathPenalty = false, respawnSec = 10 },
}

InstancePvp._kindById = InstancePvp._kindById or {}
InstancePvp._hooks = InstancePvp._hooks or {}

local function normalizeId(instanceId)
	return math.floor(tonumber(instanceId) or 0)
end

--- Bind a private instance id to a kind and push its world type to the engine.
function InstancePvp.apply(instanceId, kind)
	local id = normalizeId(instanceId)
	if id == 0 then
		return false
	end
	local rules = InstancePvp.KINDS[kind]
	if not rules then
		logger.warn("[InstancePvp] unknown instance kind '{}' for instance {}; using main world rules", tostring(kind), id)
		kind = "world"
		rules = InstancePvp.KINDS.world
	end
	InstancePvp._kindById[id] = kind
	if Game.setInstanceWorldType then
		Game.setInstanceWorldType(id, rules.worldType or Game.getWorldType(0))
	end
	return true
end

--- Drop the kind binding (the engine clears its override in Game.releaseInstance).
function InstancePvp.forget(instanceId)
	InstancePvp._kindById[normalizeId(instanceId)] = nil
end

function InstancePvp.kindOf(instanceId)
	return InstancePvp._kindById[normalizeId(instanceId)] or "world"
end

function InstancePvp.rulesFor(creature)
	local instanceId = creature and creature.getInstanceId and creature:getInstanceId() or 0
	local kind = InstancePvp.kindOf(instanceId)
	return InstancePvp.KINDS[kind] or InstancePvp.KINDS.world, kind
end

--- Content hooks around the no-penalty knockout for a kind.
--- hooks.beforeKnockout(player), hooks.onRevive(player)
function InstancePvp.setHooks(kind, hooks)
	InstancePvp._hooks[kind] = hooks
end

function InstancePvp.respawnSec(kind)
	local rules = InstancePvp.KINDS[kind] or {}
	return math.max(1, tonumber(rules.respawnSec) or (SoftDeathConfig and SoftDeathConfig.DEFAULT_DURATION_SEC) or 10)
end

local function knockout(player, kind)
	local delay = InstancePvp.respawnSec(kind)
	local hooks = InstancePvp._hooks[kind] or {}
	if hooks.beforeKnockout then
		pcall(hooks.beforeKnockout, player)
	end
	if not (SoftDeath and SoftDeath.beginDowned) then
		return false
	end
	local ok = SoftDeath.beginDowned(player, {
		reason = kind,
		title = "Knocked out",
		message = "Respawning in place...",
		durationSec = delay,
		onRevive = function(p)
			if hooks.onRevive then
				hooks.onRevive(p)
			end
		end,
	})
	if ok then
		player:sendTextMessage(MESSAGE_EVENT_ADVANCE, string.format("Knocked out! Respawning in %ds...", delay))
	end
	return ok
end

--- Lethal damage in a no-death-penalty instance becomes a timed knockout.
function InstancePvp.onHealthChange(creature, attacker, primaryDamage, primaryType, secondaryDamage, secondaryType, origin)
	local player = creature and creature:getPlayer()
	if not player then
		return primaryDamage, primaryType, secondaryDamage, secondaryType
	end
	local rules, kind = InstancePvp.rulesFor(player)
	if rules.deathPenalty ~= false then
		return primaryDamage, primaryType, secondaryDamage, secondaryType
	end
	if SoftDeath and SoftDeath.isDowned and SoftDeath.isDowned(player) then
		return 0, primaryType, 0, secondaryType
	end

	local dmg = 0
	local pDmg = tonumber(primaryDamage) or 0
	local sDmg = tonumber(secondaryDamage) or 0
	if pDmg < 0 then
		dmg = dmg - pDmg
	end
	if sDmg < 0 then
		dmg = dmg - sDmg
	end
	if dmg <= 0 or player:getHealth() - dmg > 0 then
		return primaryDamage, primaryType, secondaryDamage, secondaryType
	end

	-- Absorb the lethal hit either way so a true death never fires here.
	knockout(player, kind)
	return 0, primaryType, 0, secondaryType
end

--- Fallback if a death still happens: no loot or skill loss.
function InstancePvp.onPrepareDeath(player)
	if not player then
		return true
	end
	local rules = InstancePvp.rulesFor(player)
	if rules.deathPenalty == false then
		if player.setDropLoot then
			player:setDropLoot(false)
		end
		if player.setSkillLoss then
			player:setSkillLoss(false)
		end
	end
	return true
end
