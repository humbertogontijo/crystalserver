-- Shared gold/cap shortage: auto-sell then suspend that character's automation
-- (optionally still abort the expedition when session stop flags are set).

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

local function suspendPlayerAutomation(player, kind)
	if not player or not CombatAutomation then
		return
	end
	local state = CombatAutomation.getState and CombatAutomation.getState(player)
	-- Already suspended: do not re-notify (potion/ammo retries every tick would spam).
	if state and state.suspended == true then
		return
	end
	if CombatAutomation.setSuspended then
		CombatAutomation.setSuspended(player, true)
	elseif state then
		state.suspended = true
	end
	if CombatAutomationProtocol and CombatAutomationProtocol.send then
		pcall(function()
			CombatAutomationProtocol.send(player, {
				action = "setAutomationSuspended",
				suspended = true,
				reason = kind,
			})
		end)
	end
	if player.sendTextMessage then
		-- MESSAGE_STATUS_WARNING is not a valid MessageClasses value (becomes MESSAGE_NONE).
		if kind == "gold" then
			player:sendTextMessage(MESSAGE_STATUS, "Automation suspended: not enough gold.")
		elseif kind == "cap" then
			player:sendTextMessage(MESSAGE_STATUS, "Automation suspended: not enough capacity.")
		else
			player:sendTextMessage(MESSAGE_STATUS, "Automation suspended due to a supply shortage.")
		end
	end
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
		return false
	end

	-- Headless companions cannot clear UI suspend and often share host economy timing;
	-- skip this buy only so targeting/casting keep running when supplies exist.
	if player.isHeadless and player:isHeadless() then
		return false
	end

	-- Default: suspend this character's automation only (do not end the hunt).
	suspendPlayerAutomation(player, kind)
	return false
end
