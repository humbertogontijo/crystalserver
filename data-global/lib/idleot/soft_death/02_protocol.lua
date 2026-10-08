SoftDeathProtocol = SoftDeathProtocol or {}

SoftDeathProtocol.send = IdleUtil.jsonSender(SoftDeathConfig.OPCODE)

--- Notify client that the local player is soft-downed (knock-out UI; not GameServerDeath).
function SoftDeathProtocol.sendDowned(player, opts)
	opts = opts or {}
	local durationSec = math.max(1, tonumber(opts.durationSec) or SoftDeathConfig.DEFAULT_DURATION_SEC or 10)
	local untilTs = tonumber(opts.untilTs) or (os.time() + durationSec)
	return SoftDeathProtocol.send(player, {
		type = "softDeath",
		reason = opts.reason or "generic",
		title = opts.title or SoftDeathConfig.DEFAULT_TITLE,
		message = opts.message or SoftDeathConfig.DEFAULT_MESSAGE,
		durationSec = durationSec,
		untilTs = untilTs,
	})
end

--- Clear soft-death UI after revive / leave.
function SoftDeathProtocol.sendRevive(player, opts)
	opts = opts or {}
	return SoftDeathProtocol.send(player, {
		type = "softRevive",
		reason = opts.reason or "generic",
	})
end
