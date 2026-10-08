-- Per-instance-kind rules: PvP mode (stock world types), death rules and the player cap
-- per channel. Combat, skulls and secure mode stay stock; the engine resolves the world
-- type per instance key (Game.getWorldType(instanceId)): per-key override, then the
-- kind's type, then the world's own type from `worlds.type`.
InstanceKinds = InstanceKinds or {}

-- worldType: stock world type for every channel of this kind (nil = main world type).
-- sessionWorldType: world type of reserved (private session) channels only.
-- deathPenalty = false: lethal damage knocks the player out (soft death) and they
--   respawn in place after respawnSec, with no loot or skill loss.
-- maxPlayers: public channel cap; a new channel opens when every channel is full (0 = no cap).
InstanceKinds.KINDS = {
	world = {},
	city = { maxPlayers = 150 },
	settlement = { maxPlayers = 80 },
	hub = { maxPlayers = 150 },
	wild = { maxPlayers = 60 },
	hunt = { sessionWorldType = WORLDTYPE_OPTIONAL, maxPlayers = 30 },
	connector = {},
	lobby = { worldType = WORLDTYPE_OPTIONAL },
	raid = { worldType = WORLDTYPE_OPTIONAL },
	soulpit = { worldType = WORLDTYPE_OPTIONAL },
	arena = { worldType = WORLDTYPE_OPTIONAL },
	worldboss = { worldType = WORLDTYPE_OPEN, deathPenalty = false, respawnSec = 10 },
}

InstanceKinds._hooks = InstanceKinds._hooks or {}

--- Push per-kind world types and channel caps to the engine (startup / reload).
function InstanceKinds.register()
	for kind, rules in pairs(InstanceKinds.KINDS) do
		if kind ~= "world" then
			Game.setInstanceKindWorldType(kind, rules.worldType)
			Game.setInstanceKindCapacity(kind, math.max(0, tonumber(rules.maxPlayers) or 0))
		end
	end
end

--- Apply session rules to a freshly allocated private channel (rules follow the engine kind).
function InstanceKinds.apply(instanceId)
	local key = Instance.normalize(instanceId)
	if not key or Instance.isWorld(key) then
		return false
	end
	local kind = Instance.kind(key)
	local rules = InstanceKinds.KINDS[kind]
	if not rules then
		logger.warn("[InstanceKinds] unknown instance kind '{}' for {}; using main world rules", tostring(kind), key)
		return false
	end
	local worldType = rules.sessionWorldType or rules.worldType
	if worldType then
		Game.setInstanceWorldType(key, worldType)
	end
	return true
end

--- Rules kind of an instance key.
function InstanceKinds.kindOf(instanceId)
	return Instance.kind(instanceId) or "world"
end

function InstanceKinds.rulesFor(creature)
	local kind = InstanceKinds.kindOf(Instance.of(creature))
	return InstanceKinds.KINDS[kind] or InstanceKinds.KINDS.world, kind
end

--- Content hooks around the no-penalty knockout for a kind.
--- hooks.beforeKnockout(player), hooks.onRevive(player)
function InstanceKinds.setHooks(kind, hooks)
	InstanceKinds._hooks[kind] = hooks
end

function InstanceKinds.respawnSec(kind)
	local rules = InstanceKinds.KINDS[kind] or {}
	return math.max(1, tonumber(rules.respawnSec) or (SoftDeathConfig and SoftDeathConfig.DEFAULT_DURATION_SEC) or 10)
end

local function knockout(player, kind)
	local delay = InstanceKinds.respawnSec(kind)
	local hooks = InstanceKinds._hooks[kind] or {}
	if hooks.beforeKnockout then
		IdleSafe.call("InstanceKinds.beforeKnockout", hooks.beforeKnockout, player)
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
function InstanceKinds.onHealthChange(creature, attacker, primaryDamage, primaryType, secondaryDamage, secondaryType, origin)
	local player = creature and creature:getPlayer()
	if not player then
		return primaryDamage, primaryType, secondaryDamage, secondaryType
	end
	local rules, kind = InstanceKinds.rulesFor(player)
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
function InstanceKinds.onPrepareDeath(player)
	if not player then
		return true
	end
	local rules = InstanceKinds.rulesFor(player)
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

InstanceKinds.register()
