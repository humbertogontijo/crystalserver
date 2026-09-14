SoftDeath = SoftDeath or {}

-- playerId -> { untilTs, reason, pos, instanceId, corpseUid, event }
SoftDeath._downed = SoftDeath._downed or {}

local function corpseItemId(player)
	local female = SoftDeathConfig.FEMALE_CORPSE_ID or 4247
	local male = SoftDeathConfig.MALE_CORPSE_ID or 4240
	if player.getSex and player:getSex() == PLAYERSEX_FEMALE then
		return female
	end
	return male
end

local function clearCorpse(entry)
	if not entry or not entry.corpseUid then
		return
	end
	local item = Item(entry.corpseUid)
	if item and item.remove then
		pcall(function()
			item:remove()
		end)
	end
	entry.corpseUid = nil
end

local function cancelReviveEvent(entry)
	if entry and entry.event then
		stopEvent(entry.event)
		entry.event = nil
	end
end

function SoftDeath.isDowned(player)
	if not player then
		return false
	end
	if player.isSoftDespawned and player:isSoftDespawned() then
		return true
	end
	local entry = SoftDeath._downed[player:getId()]
	return entry ~= nil
end

--- Soft-death: place a corpse item, leave the map (real remove — no combat creature),
--- then softSpawn after the timer. Attackers / bosses lose the target via onRemoveCreature.
--- opts: reason, title, message, durationSec, untilTs, skipProtocol, position, onRevive
function SoftDeath.beginDowned(player, opts)
	if not player then
		return false
	end
	if SoftDeath.isDowned(player) then
		return false
	end
	if not player.softDespawn then
		logger.error("[SoftDeath] player:softDespawn missing — rebuild crystalserver")
		return false
	end

	opts = opts or {}
	local durationSec = math.max(1, tonumber(opts.durationSec) or SoftDeathConfig.DEFAULT_DURATION_SEC or 10)
	local untilTs = tonumber(opts.untilTs) or (os.time() + durationSec)
	local pos = opts.position or player:getPosition()
	if not pos then
		return false
	end
	local instanceId = player.getInstanceId and player:getInstanceId() or 0
	local pid = player:getId()

	if player.setFollowCreature then
		player:setFollowCreature(nil)
	end
	if player.setTarget then
		player:setTarget(nil)
	end
	if player.setIdleCombat then
		player:setIdleCombat(false)
	end

	local corpseUid = nil
	local corpse = Game.createItem(corpseItemId(player), 1)
	if corpse then
		corpse:moveTo(Position(pos.x, pos.y, pos.z))
		if corpse.setInstanceId then
			corpse:setInstanceId(instanceId)
		end
		corpseUid = corpse.getUniqueId and corpse:getUniqueId() or nil
	end

	SoftDeath._downed[pid] = {
		untilTs = untilTs,
		reason = opts.reason or "generic",
		pos = { x = pos.x, y = pos.y, z = pos.z },
		instanceId = instanceId,
		corpseUid = corpseUid,
		onRevive = opts.onRevive,
	}

	if not player:softDespawn() then
		clearCorpse(SoftDeath._downed[pid])
		SoftDeath._downed[pid] = nil
		logger.error("[SoftDeath] softDespawn failed for {}", player:getName())
		return false
	end

	if not opts.skipProtocol and SoftDeathProtocol and SoftDeathProtocol.sendDowned then
		SoftDeathProtocol.sendDowned(player, {
			reason = opts.reason,
			title = opts.title,
			message = opts.message,
			durationSec = durationSec,
			untilTs = untilTs,
		})
	end

	local entry = SoftDeath._downed[pid]
	entry.event = addEvent(function()
		local p = Player(pid)
		if not p then
			local stale = SoftDeath._downed[pid]
			clearCorpse(stale)
			SoftDeath._downed[pid] = nil
			return
		end
		SoftDeath.endDowned(p, { reason = entry.reason, revive = true })
	end, durationSec * 1000)

	return true
end

--- Clear soft-death. opts.revive (default true) softSpawns at downed pos; false → temple.
--- opts: reason, skipProtocol, revive (bool), runCallback (bool, default true)
function SoftDeath.endDowned(player, opts)
	if not player then
		return false
	end
	opts = opts or {}
	local pid = player:getId()
	local entry = SoftDeath._downed[pid]
	local wasDowned = entry ~= nil or (player.isSoftDespawned and player:isSoftDespawned())
	if not wasDowned then
		return false
	end

	cancelReviveEvent(entry)
	clearCorpse(entry)
	SoftDeath._downed[pid] = nil

	if player.isSoftDespawned and player:isSoftDespawned() and player.softSpawn then
		local spawnPos
		if opts.revive == false then
			-- Leave / eject mid-knockout: do not reappear on the arena tile.
			spawnPos = player:getTemplePosition()
		else
			local pos = entry and entry.pos
			spawnPos = pos and Position(pos.x, pos.y, pos.z) or player:getPosition()
		end
		if not player:softSpawn(spawnPos) then
			logger.error("[SoftDeath] softSpawn failed for {}", player:getName())
		end
	end

	if wasDowned and not opts.skipProtocol and SoftDeathProtocol and SoftDeathProtocol.sendRevive then
		SoftDeathProtocol.sendRevive(player, { reason = opts.reason or (entry and entry.reason) })
	end

	if opts.runCallback ~= false and entry and type(entry.onRevive) == "function" then
		pcall(entry.onRevive, player)
	end

	if ExpeditionAI and ExpeditionAI.enablePersistence then
		ExpeditionAI.enablePersistence(player)
	end
	if CombatAutomation and CombatAutomation.ensureLoop then
		CombatAutomation.ensureLoop(player)
	end
	return true
end
