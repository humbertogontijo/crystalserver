-- Shared gold/cap shortage: auto-sell then expedition stop (opt-in stop flags on session).

ExpeditionSafety = ExpeditionSafety or {}

local function sessionFor(player)
	if not player or not ExpeditionManager or not ExpeditionManager.getSessionByPlayer then
		return nil
	end
	return ExpeditionManager.getSessionByPlayer(player)
end

local function shouldStop(session, kind)
	if not session then
		return false
	end
	if kind == "gold" then
		return session.stopOnInsufficientGold == true
	end
	if kind == "cap" then
		return session.stopOnInsufficientCap == true
	end
	return false
end

--- kind: "gold" | "cap"
--- retryFn(): true when the blocked action now succeeds
--- abortReason: expedition abort message when stop option is enabled
--- Returns true when retryFn succeeds (including when already ok before sell).
function ExpeditionSafety.handleShortage(player, kind, retryFn, abortReason)
	if not player or not player.isPlayer or not player:isPlayer() then
		return false
	end
	if type(retryFn) ~= "function" then
		return false
	end

	if RemoteHirelingEconomy and RemoteHirelingEconomy.maybeSellForShortage then
		RemoteHirelingEconomy.maybeSellForShortage(player, kind)
	end

	if retryFn() then
		return true
	end

	local session = sessionFor(player)
	if shouldStop(session, kind) and ExpeditionManager and ExpeditionManager.abort then
		local name = player.getName and player:getName() or "Adventurer"
		local reason = abortReason
		if not reason or reason == "" then
			if kind == "gold" then
				reason = string.format("%s ran out of gold. Expedition stopped.", name)
			else
				reason = string.format("%s has insufficient capacity. Expedition stopped.", name)
			end
		end
		ExpeditionManager.abort(session, reason)
	end
	return false
end
