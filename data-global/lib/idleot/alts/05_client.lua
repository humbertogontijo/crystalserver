-- Client attach / detach hooks called from C++ (ProtocolGame connect / detach).
Alts = Alts or {}

--- Same-account controller that should own this headless body (lobby host).
local function resolveController(player)
	if type(Alts.controllerResolver) ~= "function" then
		return nil
	end
	local ok, controller = pcall(Alts.controllerResolver, player)
	if ok then
		return controller
	end
	return nil
end

--- Clear companion mark while a UI client is attached.
function Alts.onAttachedClient(player)
	if not player then
		return
	end
	if player.setHeadless then
		player:setHeadless(false)
	end
	if Alts.isCompanion(player) then
		Alts.clearCompanionMark(player)
	end
	-- Drop sticky expedition companion flag so hunt-death / accept UX treats this
	-- client as a human viewer (storage mark alone is not enough).
	if ExpeditionManager and ExpeditionManager.getSessionByPlayer then
		local session = ExpeditionManager.getSessionByPlayer(player)
		if session and session.companionIds then
			session.companionIds[player:getId()] = nil
		end
	end
end

--- Called from C++ ProtocolGame::connect after a real client attaches.
function Alts.onClientAttached(player)
	if not player then
		return
	end
	Alts.onAttachedClient(player)

	if LobbyManager and LobbyManager.onClientAttached then
		pcall(LobbyManager.onClientAttached, player)
	end
	if ExpeditionManager and ExpeditionManager.syncSessionClientIfNeeded then
		pcall(ExpeditionManager.syncSessionClientIfNeeded, player)
	end
	-- Attached bodies are already bound, so the login-time instance bind never pushes identity.
	if InstanceWorld and InstanceWorld.scheduleSendBounds then
		pcall(InstanceWorld.scheduleSendBounds, player)
	end
	-- Discovery skips clientless logins; push cyclopedia map state now that a UI exists.
	if DiscoverySystem and DiscoverySystem.onClientAttached then
		pcall(DiscoverySystem.onClientAttached, player)
	end
end

--- A real client detached and the creature stays online as headless.
--- Restores the same-account companion mark so expedition/lobby treat them as companions again.
function Alts.onBecameHeadless(player)
	if not player then
		return
	end
	if player.setHeadless then
		player:setHeadless(true)
	end
	local host = resolveController(player)
	if not host or host:getId() == player:getId() or not Alts.sameAccount(host, player) then
		return
	end
	Alts.markCompanion(player, host)
	-- Keep expedition session membership as companion (blocks accept prompts).
	if ExpeditionManager and ExpeditionManager.getSessionByPlayer then
		local session = ExpeditionManager.getSessionByPlayer(player) or ExpeditionManager.getSessionByPlayer(host)
		if session then
			session.companionIds = session.companionIds or {}
			session.companionIds[player:getId()] = true
			if session.memberGuids then
				session.memberGuids[player:getGuid()] = player:getId()
			end
		end
	end
	logger.info("[Alts] {} became headless companion under {}", player:getName(), host:getName())
end

--- Called from C++ ProtocolGame::release when the creature stays online without a UI.
function Alts.onClientDetached(player)
	if not player then
		return
	end
	-- Lobby handoff first so the headless body is re-marked under the new host.
	if LobbyManager and LobbyManager.onClientDetached then
		pcall(LobbyManager.onClientDetached, player)
	end
	Alts.onBecameHeadless(player)
end
