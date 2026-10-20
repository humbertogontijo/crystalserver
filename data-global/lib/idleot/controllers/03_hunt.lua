-- Hunt begin / recall helpers shared by catalog hunts.
-- Mission hunt steps select the expedition on the lobby instead of joining.

PlayerController.Hunt = PlayerController.Hunt or {}

--- Start (or switch into) a catalog hunt for `player`. Returns ok, err.
function PlayerController.Hunt.begin(player, expeditionId, opts)
	opts = opts or {}
	if not player or not ExpeditionManager or not ExpeditionManager.join then
		return false, "Expedition unavailable."
	end
	local role = opts.role or "monster"
	ExpeditionManager.join(player, expeditionId, role, opts.loadout, opts.lure, opts)
	return true
end

--- Stop lure and leave the hunt with loot grace (Fiendish / mission quota / boss exit).
function PlayerController.Hunt.recall(player, opts)
	opts = opts or {}
	if not player or not ExpeditionManager then
		return false
	end
	local session = ExpeditionManager.getSessionByPlayer(player)
	if not session then
		return false
	end
	if ExpeditionAI and ExpeditionAI.stop then
		ExpeditionAI.stop(session)
	end
	local endMsg = opts.endMsg
	local victory = opts.victory == true
	if ExpeditionManager.scheduleSessionExit then
		ExpeditionManager.scheduleSessionExit(session, {
			victory = victory,
			endMsg = endMsg,
			delayMs = opts.delayMs,
		})
		return true
	end
	ExpeditionManager.leave(player, { silent = true, victory = victory })
	return true
end

--- Host picks `expeditionId` for their lobby. Creates a personal lobby when they have none.
function PlayerController.Hunt.selectForLobby(player, expeditionId, opts)
	opts = opts or {}
	if not player or expeditionId == nil or tostring(expeditionId) == "" then
		return false, "Unknown expedition."
	end
	if not LobbyStore or not LobbyManager then
		return false, "Lobby unavailable."
	end
	local record = LobbyStore.getForPlayer(player)
	if record and not LobbyStore.isHost(record, player) then
		return false, "Only the lobby host can choose the expedition."
	end
	if not record then
		record = LobbyManager.ensureForPlayer(player)
	end
	if not record or not LobbyStore.isHost(record, player) then
		return false, "Could not open a lobby."
	end
	local ok, err = LobbyManager.update(player, {
		expeditionId = tostring(expeditionId),
		role = opts.role or "monster",
	})
	if not ok then
		return false, err or "Could not select the expedition."
	end
	local name = tostring(record.expeditionName or "")
	if name ~= "" then
		player:sendTextMessage(MESSAGE_EVENT_ADVANCE, name .. " selected for your lobby.")
	else
		player:sendTextMessage(MESSAGE_EVENT_ADVANCE, "Selected for your lobby.")
	end
	return true
end

--- Convenience on the controller instance.
function PlayerController:beginHunt(expeditionId, opts)
	return PlayerController.Hunt.begin(self:player(), expeditionId, opts)
end

function PlayerController:recallHunt(opts)
	return PlayerController.Hunt.recall(self:player(), opts)
end
