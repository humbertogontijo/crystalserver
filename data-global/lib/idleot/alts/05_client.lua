-- Client attach / detach (scripts/idleot/alts/events.lua).
Alts = Alts or {}

--- Same-account controller that should own this headless body (lobby host).
local function resolveController(player)
	if type(Alts.controllerResolver) ~= "function" then
		return nil
	end
	local ok, controller = IdleSafe.call("Alts.controllerResolver", Alts.controllerResolver, player)
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
	player:setHeadless(false)
	if Alts.isCompanion(player) then
		Alts.clearCompanionMark(player)
	end
	-- Drop sticky expedition companion flag so hunt-death / accept UX treats this
	-- client as a human viewer (storage mark alone is not enough).
	local session = ExpeditionManager.getSessionByPlayer(player)
	if session and session.companionIds then
		session.companionIds[player:getId()] = nil
	end
end

--- playerOnClientAttach: a real client took over a body that stayed online. Per-module UI
--- state is pushed by the playerOnClientReady handlers that follow.
function Alts.onClientAttached(player)
	Alts.onAttachedClient(player)
	-- Lobby handoff needs the companion mark cleared first.
	IdleSafe.call("LobbyManager.onClientAttached", LobbyManager.onClientAttached, player)
	IdleSafe.call("LobbyServices.onClientAttached", LobbyServices.onClientAttached, player)
end

--- A real client detached and the creature stays online as headless.
--- Restores the same-account companion mark so expedition/lobby treat them as companions again.
function Alts.onBecameHeadless(player)
	if not player then
		return
	end
	player:setHeadless(true)
	local host = resolveController(player)
	if not host or host:getId() == player:getId() or not Alts.sameAccount(host, player) then
		return
	end
	Alts.markCompanion(player, host)
	-- Keep expedition session membership as companion (blocks accept prompts).
	local session = ExpeditionManager.getSessionByPlayer(player) or ExpeditionManager.getSessionByPlayer(host)
	if session then
		session.companionIds = session.companionIds or {}
		session.companionIds[player:getId()] = true
		if session.memberGuids then
			session.memberGuids[player:getGuid()] = player:getId()
		end
	end
	logger.info("[Alts] {} became headless companion under {}", player:getName(), host:getName())
end

--- playerOnClientDetach: the client left and the creature stays online without a UI.
function Alts.onClientDetached(player)
	-- Lobby handoff first so the headless body is re-marked under the new host.
	IdleSafe.call("LobbyManager.onClientDetached", LobbyManager.onClientDetached, player)
	Alts.onBecameHeadless(player)
end
