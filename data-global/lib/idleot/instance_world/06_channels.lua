-- Open-world channel switching: list the public channels of the player's {kind, subarea} and
-- hop between them in place after an instance teleport cast. Gods switch instantly (/instance).
-- Channels are 0-based here and on the wire; the top bar shows them 1-based.

-- Public open-world kinds; private sessions (hunt expeditions, lobbies, raids) never switch.
InstanceWorld.SWITCHABLE_CHANNEL_KINDS = {
	city = true,
	settlement = true,
	hub = true,
	wild = true,
	hunt = true,
	connector = true,
}
InstanceWorld.CHANNEL_SWITCH_COOLDOWN_SEC = 60
-- Offer a fresh channel once every public channel is this full.
InstanceWorld.CHANNEL_NEW_THRESHOLD = 0.8
local KV_SWITCH_AT = "instance_channel_switch_at"

local function capFor(kind)
	local rules = InstanceKinds and InstanceKinds.KINDS[kind]
	return math.max(0, tonumber(rules and rules.maxPlayers) or 0)
end

local function label(channel)
	return string.format("%02d", (tonumber(channel) or 0) + 1)
end
InstanceWorld.channelLabel = label

local function cooldownLeft(player)
	local at = tonumber(player:kv():get(KV_SWITCH_AT)) or 0
	return math.max(0, at + InstanceWorld.CHANNEL_SWITCH_COOLDOWN_SEC - os.time())
end

--- Current public open-world layer of the player: parsed key, or nil + reason.
local function switchableLayer(player)
	local key = Instance.of(player)
	if Instance.isWorld(key) or Instance.isPrivate(key) then
		return nil, "Channels can only be switched in the open world."
	end
	local parsed = Instance.parse(key)
	if not parsed or not InstanceWorld.SWITCHABLE_CHANNEL_KINDS[parsed.kind] then
		return nil, "Channels can only be switched in the open world."
	end
	return parsed
end

--- Public channels of the player's layer: { kind, subareaId, name, cap, current, cooldown,
--- channels = { {channel, players, full, current} }, newChannel }; nil + error outside it.
function InstanceWorld.listChannels(player)
	local parsed, err = switchableLayer(player)
	if not parsed then
		return nil, err
	end
	local cap = capFor(parsed.kind)
	local rows, seen = {}, {}
	local crowded, maxChannel = true, 0
	for _, row in ipairs(Game.getInstanceChannels(parsed.kind, parsed.subareaId) or {}) do
		local channel = tonumber(row.channel) or 0
		maxChannel = math.max(maxChannel, channel)
		if not row.reserved then
			local players = tonumber(row.players) or 0
			seen[channel] = true
			rows[#rows + 1] = {
				channel = channel,
				players = players,
				full = cap > 0 and players >= cap,
				current = channel == parsed.channel,
			}
			if cap == 0 or players < cap * InstanceWorld.CHANNEL_NEW_THRESHOLD then
				crowded = false
			end
		end
	end
	if not seen[parsed.channel] then
		rows[#rows + 1] = { channel = parsed.channel, players = 1, full = false, current = true }
	end
	table.sort(rows, function(a, b)
		return a.channel < b.channel
	end)
	local desc = InstanceWorld.describeCurrent(player)
	return {
		kind = parsed.kind,
		subareaId = parsed.subareaId,
		name = desc and desc.name or parsed.kind,
		cap = cap,
		current = parsed.channel,
		cooldown = PzTeleport.isGod(player) and 0 or cooldownLeft(player),
		channels = rows,
		newChannel = crowded and cap > 0 and (maxChannel + 1) or nil,
	}
end

--- Move the player onto `channel` of their current {kind, subarea} without moving them.
--- opts.bypass (gods): any live channel, private ones included, and no player cap.
--- Returns the new instance key, or nil + error.
function InstanceWorld.switchChannelNow(player, channel, opts)
	opts = opts or {}
	local current = Instance.of(player)
	if Instance.isWorld(current) then
		return nil, "The open world template has no channels."
	end
	local parsed = Instance.parse(current)
	if channel == parsed.channel then
		return nil, "You are already on channel " .. label(channel) .. "."
	end
	local target = Instance.withChannel(current, channel)
	-- Live channels of a private layer (or any live channel for gods) are entered directly.
	local direct = Instance.isLive(target) and (opts.bypass or Instance.isPrivate(current))
	if not direct then
		if Instance.isPrivate(current) then
			return nil, "Channel " .. label(channel) .. " is not open for " .. parsed.kind .. "."
		end
		-- Opens the public channel on demand; a full or reserved one resolves elsewhere.
		target = Game.pickInstanceChannel(parsed.kind, parsed.subareaId, channel, player)
		if not target or Instance.channel(target) ~= channel then
			return nil, "Channel " .. label(channel) .. " is full."
		end
	end
	if not InstanceWorld.setInstanceInPlace(player, target) then
		return nil, "Could not switch to channel " .. label(channel) .. "."
	end
	InstanceWorld.sendBounds(player, true)
	return target
end

local function sendChannels(player)
	local list, err = InstanceWorld.listChannels(player)
	local payload = list or { error = err }
	payload.type = "instanceChannels"
	IdleUtil.sendJson(player, InstanceTeleport.OPCODE, payload)
end
InstanceWorld.sendChannels = sendChannels

--- Player request: cast, then switch. Refuses PZ-lock, fights, cooldown and full channels.
function InstanceWorld.requestChannelSwitch(player, channel)
	channel = math.floor(tonumber(channel) or -1)
	if channel < 0 or channel > 65535 then
		return false, "Choose a channel."
	end
	local parsed, err = switchableLayer(player)
	if not parsed then
		return false, err
	end
	if channel == parsed.channel then
		return false, "You are already on channel " .. label(channel) .. "."
	end
	if PzTeleport.isGod(player) then
		local key, switchErr = InstanceWorld.switchChannelNow(player, channel, { bypass = true })
		if not key then
			return false, switchErr
		end
		sendChannels(player)
		return true
	end
	if PzTeleport.isCombatLocked(player) then
		return false, "You cannot switch channels while PZ-locked."
	end
	if player:hasCondition(CONDITION_INFIGHT) then
		return false, "You cannot switch channels during a fight."
	end
	local wait = cooldownLeft(player)
	if wait > 0 then
		return false, string.format("You can switch channels again in %d seconds.", wait)
	end
	-- Only listed public channels, or the fresh one offered when all are crowded.
	local list = InstanceWorld.listChannels(player)
	local row = nil
	for _, r in ipairs(list and list.channels or {}) do
		if r.channel == channel then
			row = r
		end
	end
	if not row and channel ~= (list and list.newChannel) then
		return false, "Channel " .. label(channel) .. " is not open."
	end
	if row and row.full then
		return false, "Channel " .. label(channel) .. " is full."
	end
	local fromKey = parsed.key
	return InstanceTeleport.requestChannel(player, {
		onComplete = function(p)
			if Instance.of(p) ~= fromKey then
				p:sendTextMessage(MESSAGE_FAILURE, "You left the area; channel switch cancelled.")
				return
			end
			local key, switchErr = InstanceWorld.switchChannelNow(p, channel)
			if not key then
				p:sendTextMessage(MESSAGE_FAILURE, switchErr)
				sendChannels(p)
				return
			end
			p:kv():set(KV_SWITCH_AT, os.time())
			p:getPosition():sendMagicEffect(CONST_ME_TELEPORT)
			p:sendTextMessage(MESSAGE_EVENT_ADVANCE, "You are now on channel " .. label(channel) .. ".")
			sendChannels(p)
		end,
	})
end
