-- Server-timed instance teleport channel (hometown / lobby / expedition).
-- Client VFX is cosmetic; this module owns duration + cancel policy.
InstanceTeleport = InstanceTeleport or {}

-- Travel opcode (recall, lobby room, channel cancel); distinct from expedition (113).
InstanceTeleport.OPCODE = 116
InstanceTeleport.DURATION_PZ_MS = 5000
InstanceTeleport.DURATION_WILD_MS = 30000
InstanceTeleport.KIND_HOMETOWN = "hometown"
InstanceTeleport.KIND_LOBBY = "lobby"
InstanceTeleport.KIND_EXPEDITION = "expedition"
-- Open-world channel switch (same place, another public channel).
InstanceTeleport.KIND_CHANNEL = "channel"
InstanceTeleport.CHANNEL_SWITCH_MAX_MS = 10000
-- Where a hop lands; picks the aura tint (kind only drives policy and client UI).
InstanceTeleport.DEST_OPEN_WORLD = InstanceTeleport.KIND_HOMETOWN
InstanceTeleport.DEST_LOBBY = InstanceTeleport.KIND_LOBBY
InstanceTeleport.DEST_EXPEDITION = InstanceTeleport.KIND_EXPEDITION
InstanceTeleport.CANCEL_INITIATOR = "initiator"
InstanceTeleport.CANCEL_ANY = "any"
InstanceTeleport.CANCEL_NONE = "none"

-- groupKey -> pending
local pendingByGroup = {}
-- playerId -> groupKey
local groupByPlayerId = {}

local nextGroupSeq = 1

local function nowMs()
	if type(systemTime) == "function" then
		return math.floor(systemTime())
	end
	return os.time() * 1000
end

local function encodePayload(payload)
	if JsonParser and JsonParser.encode then
		local ok, encoded = pcall(JsonParser.encode, payload)
		if ok and type(encoded) == "string" then
			return encoded
		end
	end
	-- Minimal fallback for channel payloads.
	local kind = tostring(payload.kind or "")
	local t = tostring(payload.type or "")
	-- Include holdUntilReady in channelStart so clients keep FX past the bar.
	if t == "channelStart" then
		return string.format(
			'{"type":"channelStart","kind":%q,"durationMs":%d,"canCancel":%s,"holdUntilReady":%s}',
			kind,
			math.floor(tonumber(payload.durationMs) or 0),
			payload.canCancel and "true" or "false",
			payload.holdUntilReady and "true" or "false"
		)
	end
	return string.format('{"type":%q,"kind":%q}', t, kind)
end

local function defaultSend(player, payload)
	if not player or not payload then
		return
	end
	local opcode = tonumber(payload._opcode) or InstanceTeleport.OPCODE
	local body = encodePayload(payload)
	player:sendExtendedOpcode(opcode, body)
end

--- Per-player channel duration before group max.
function InstanceTeleport.durationMsFor(player, opts)
	opts = opts or {}
	local forced = tonumber(opts.forceDurationMs)
	if forced and forced > 0 then
		return math.floor(forced)
	end
	if ExpeditionManager and ExpeditionManager.isInExpedition and ExpeditionManager.isInExpedition(player) then
		return InstanceTeleport.DURATION_PZ_MS
	end
	if PzTeleport and PzTeleport.isInSafeZone and PzTeleport.isInSafeZone(player) then
		return InstanceTeleport.DURATION_PZ_MS
	end
	return InstanceTeleport.DURATION_WILD_MS
end

function InstanceTeleport.isPending(player)
	if not player then
		return false
	end
	return groupByPlayerId[player:getId()] ~= nil
end

local function auraEffectFor(destination)
	local fx = CustomEffects or {}
	if destination == InstanceTeleport.DEST_OPEN_WORLD then
		return fx.IT_AURA_HOMETOWN
	elseif destination == InstanceTeleport.DEST_LOBBY then
		return fx.IT_AURA_LOBBY
	elseif destination == InstanceTeleport.DEST_EXPEDITION then
		return fx.IT_AURA_EXPEDITION
	end
	return nil
end

--- Channel aura as a creature attached effect, so every spectator in the instance sees it.
local function setChannelAura(pending, attached)
	local effectId = auraEffectFor(pending.destination)
	if not effectId then
		return
	end
	for _, id in ipairs(pending.memberIds or {}) do
		local p = Player(id)
		if p then
			if attached then
				p:attachEffectById(effectId)
			else
				p:detachEffectById(effectId)
			end
		end
	end
end

local function clearGroup(groupKey, opts)
	opts = opts or {}
	local pending = pendingByGroup[groupKey]
	if not pending then
		return
	end
	if pending.event then
		stopEvent(pending.event)
		pending.event = nil
	end
	setChannelAura(pending, false)
	pendingByGroup[groupKey] = nil
	for _, id in ipairs(pending.memberIds or {}) do
		groupByPlayerId[id] = nil
	end
end

local function notifyMember(pending, id, payloadBase)
	local p = Player(id)
	if not p then
		return
	end
	local payload = {}
	for k, v in pairs(payloadBase) do
		payload[k] = v
	end
	payload._opcode = pending.opcode
	if payload.type == "channelStart" then
		local canCancel = false
		if pending.cancelPolicy == InstanceTeleport.CANCEL_ANY then
			canCancel = true
		elseif pending.cancelPolicy == InstanceTeleport.CANCEL_INITIATOR then
			canCancel = id == pending.initiatorId
		end
		payload.canCancel = canCancel
	end
	local send = pending.send or defaultSend
	send(p, payload)
end

local function notifyMembers(pending, payloadBase)
	for _, id in ipairs(pending.memberIds or {}) do
		notifyMember(pending, id, payloadBase)
	end
end

local function completeGroup(groupKey)
	local pending = pendingByGroup[groupKey]
	if not pending then
		return
	end
	local memberIds = pending.memberIds or {}
	local kind = pending.kind
	local onComplete = pending.onComplete
	local send = pending.send or defaultSend
	local opcode = pending.opcode
	clearGroup(groupKey)
	for _, id in ipairs(memberIds) do
		local p = Player(id)
		if p then
			send(p, { type = "channelComplete", kind = kind, _opcode = opcode })
		end
	end
	if onComplete then
		pcall(onComplete, memberIds)
	end
end

local function tryFinishGroup(groupKey)
	local pending = pendingByGroup[groupKey]
	if not pending then
		return
	end
	if not pending.timerElapsed then
		return
	end
	if pending.holdUntilReady and not pending.ready then
		return
	end
	completeGroup(groupKey)
end

--- Solo or multi-member channel.
--- opts.holdUntilReady: timer alone does not complete; call markReady(groupKey) when prep is done.
--- opts.ignoreCombatLock: server-forced hops (run ended) that must happen regardless of PZ lock.
--- opts.destination: DEST_* where the hop lands (aura tint); defaults to the kind's usual destination.
function InstanceTeleport.beginGroup(opts)
	opts = opts or {}
	local kind = tostring(opts.kind or "")
	local memberIds = opts.memberIds or {}
	if #memberIds == 0 and opts.player then
		memberIds = { opts.player:getId() }
	end
	if #memberIds == 0 then
		return false, "No members."
	end

	local initiatorId = tonumber(opts.initiatorId) or memberIds[1]
	local cancelPolicy = opts.cancelPolicy
	if not cancelPolicy then
		if kind == InstanceTeleport.KIND_EXPEDITION then
			cancelPolicy = InstanceTeleport.CANCEL_ANY
		else
			cancelPolicy = InstanceTeleport.CANCEL_INITIATOR
		end
	end

	-- Combat lock blocks arming (still hard-fail).
	local checkCombatLock = opts.ignoreCombatLock ~= true
	for _, id in ipairs(memberIds) do
		local p = Player(id)
		if checkCombatLock and p and PzTeleport and PzTeleport.isCombatLocked and PzTeleport.isCombatLocked(p) and not (PzTeleport.isGod and PzTeleport.isGod(p)) then
			return false, PzTeleport.PZ_LOCKED_MESSAGE
		end
		if p and InstanceTeleport.isPending(p) then
			return false, "Already channeling a teleport."
		end
	end

	local force = tonumber(opts.forceDurationMs)
	local durationMs = 0
	if force and force > 0 then
		durationMs = math.floor(force)
	else
		for _, id in ipairs(memberIds) do
			local p = Player(id)
			if p then
				local d = InstanceTeleport.durationMsFor(p, {})
				if d > durationMs then
					durationMs = d
				end
			end
		end
		if durationMs <= 0 then
			durationMs = InstanceTeleport.DURATION_PZ_MS
		end
	end

	local groupKey = "it_" .. tostring(nextGroupSeq)
	nextGroupSeq = nextGroupSeq + 1

	local holdUntilReady = opts.holdUntilReady == true
	local pending = {
		groupKey = groupKey,
		kind = kind,
		destination = opts.destination or kind,
		initiatorId = initiatorId,
		memberIds = memberIds,
		cancelPolicy = cancelPolicy,
		durationMs = durationMs,
		startedAt = nowMs(),
		opcode = tonumber(opts.opcode),
		send = opts.send,
		onComplete = opts.onComplete,
		onCancel = opts.onCancel,
		holdUntilReady = holdUntilReady,
		timerElapsed = false,
		ready = not holdUntilReady,
	}

	pendingByGroup[groupKey] = pending
	for _, id in ipairs(memberIds) do
		groupByPlayerId[id] = groupKey
	end

	notifyMembers(pending, {
		type = "channelStart",
		kind = kind,
		durationMs = durationMs,
		holdUntilReady = holdUntilReady,
	})
	setChannelAura(pending, true)

	pending.event = addEvent(function(key)
		local live = pendingByGroup[key]
		if not live then
			return
		end
		live.event = nil
		live.timerElapsed = true
		tryFinishGroup(key)
	end, durationMs, groupKey)

	return true, groupKey, durationMs
end

--- Signal that async prep for a holdUntilReady channel is done (e.g. companion deploy).
function InstanceTeleport.markReady(groupKey)
	if not groupKey then
		return false
	end
	local pending = pendingByGroup[groupKey]
	if not pending then
		return false
	end
	pending.ready = true
	tryFinishGroup(groupKey)
	return true
end

function InstanceTeleport.markReadyForPlayer(player)
	if not player then
		return false
	end
	local groupKey = groupByPlayerId[player:getId()]
	if not groupKey then
		return false
	end
	return InstanceTeleport.markReady(groupKey)
end

--- Alt switch: the UI moved from `fromPlayer` (a group member) to `toPlayer`. The new body
--- joins the channel with the remaining time; `fromPlayer` stays in so it still hops.
function InstanceTeleport.adoptMember(fromPlayer, toPlayer)
	if not fromPlayer or not toPlayer then
		return false
	end
	local groupKey = groupByPlayerId[fromPlayer:getId()]
	local pending = groupKey and pendingByGroup[groupKey]
	if not pending or pending.kind ~= InstanceTeleport.KIND_EXPEDITION then
		return false
	end
	local toId = toPlayer:getId()
	local existing = groupByPlayerId[toId]
	if existing and existing ~= groupKey then
		return false
	end
	if not existing then
		pending.memberIds[#pending.memberIds + 1] = toId
		groupByPlayerId[toId] = groupKey
		local effectId = auraEffectFor(pending.destination)
		if effectId then
			toPlayer:attachEffectById(effectId)
		end
	end
	if pending.initiatorId == fromPlayer:getId() then
		pending.initiatorId = toId
	end
	local remaining = 0
	if not pending.timerElapsed then
		remaining = math.max(0, (pending.durationMs or 0) - (nowMs() - (pending.startedAt or nowMs())))
	end
	notifyMember(pending, toId, {
		type = "channelStart",
		kind = pending.kind,
		durationMs = remaining,
		holdUntilReady = pending.holdUntilReady and not pending.ready,
	})
	return true
end

function InstanceTeleport.begin(player, opts)
	opts = opts or {}
	if not player then
		return false, "Invalid player."
	end
	opts.memberIds = { player:getId() }
	opts.initiatorId = player:getId()
	opts.player = player
	if not opts.cancelPolicy then
		opts.cancelPolicy = InstanceTeleport.CANCEL_INITIATOR
	end
	return InstanceTeleport.beginGroup(opts)
end

--- Cancel if policy allows. Clears the whole group on success.
function InstanceTeleport.cancel(player)
	if not player then
		return false
	end
	local playerId = player:getId()
	local groupKey = groupByPlayerId[playerId]
	if not groupKey then
		return false
	end
	local pending = pendingByGroup[groupKey]
	if not pending then
		groupByPlayerId[playerId] = nil
		return false
	end

	if pending.cancelPolicy == InstanceTeleport.CANCEL_NONE then
		return false
	end
	if pending.cancelPolicy == InstanceTeleport.CANCEL_INITIATOR then
		if playerId ~= pending.initiatorId then
			return false
		end
	end

	local memberIds = pending.memberIds or {}
	local kind = pending.kind
	local onCancel = pending.onCancel
	local send = pending.send or defaultSend
	local opcode = pending.opcode

	clearGroup(groupKey)

	for _, id in ipairs(memberIds) do
		local p = Player(id)
		if p then
			send(p, { type = "channelCancelled", kind = kind, _opcode = opcode })
		end
	end

	if onCancel then
		pcall(onCancel, memberIds, playerId)
	end
	return true
end

function InstanceTeleport.cancelAllForPlayer(player)
	return InstanceTeleport.cancel(player)
end
