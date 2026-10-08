-- Shared gold/cap shortage: auto-sell then retry; optionally abort when session
-- stop flags are set. Otherwise skip the blocked buy/deliver only.
-- Stamina: gate expedition entry for the whole party; abort when anyone hits 0.

ExpeditionSafety = ExpeditionSafety or {}

local function sessionFor(player)
	if not player then
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

--- True when the player may enter / stay in an expedition (stamina system off → always ok).
function ExpeditionSafety.hasStamina(player)
	if not player then
		return false
	end
	if not configManager.getBoolean(configKeys.STAMINA_SYSTEM) then
		return true
	end
	return player:getStamina() > 0
end

--- First player in `players` without stamina, or nil when all are ok.
function ExpeditionSafety.firstWithoutStamina(players)
	for _, p in ipairs(players or {}) do
		if p and not ExpeditionSafety.hasStamina(p) then
			return p
		end
	end
	return nil
end

--- Abort the player's expedition when stamina hits zero (whole private team; solo eject on shared raids).
function ExpeditionSafety.onStaminaDepleted(player)
	if not player then
		return
	end
	if not configManager.getBoolean(configKeys.STAMINA_SYSTEM) then
		return
	end
	if player:getStamina() > 0 then
		return
	end
	local session = sessionFor(player)
	if not session or session.aborting or session.endedByDeath then
		return
	end
	local name = player:getName() or "Adventurer"
	ExpeditionManager.abort(session, string.format("%s ran out of stamina. Expedition stopped.", name))
end

--- kind: "gold" | "cap"
--- retryFn(): true when the blocked action now succeeds
--- abortReason: expedition abort message when stop option is enabled
--- Returns true when retryFn succeeds (including when already ok before sell).
function ExpeditionSafety.handleShortage(player, kind, retryFn, abortReason)
	if not player or not player:isPlayer() then
		return false
	end
	if type(retryFn) ~= "function" then
		return false
	end

	RemoteHirelingEconomy.maybeSellForShortage(player, kind)

	if retryFn() then
		return true
	end

	local session = sessionFor(player)
	if shouldStop(session, kind) then
		local name = player:getName() or "Adventurer"
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
