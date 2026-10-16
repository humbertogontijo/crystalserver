-- Hunt begin / recall helpers shared by catalog hunts and mission waitKills.
-- Always go through ExpeditionManager so leave/loot-grace stay consistent.

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

--- Convenience on the controller instance.
function PlayerController:beginHunt(expeditionId, opts)
	return PlayerController.Hunt.begin(self:player(), expeditionId, opts)
end

function PlayerController:recallHunt(opts)
	return PlayerController.Hunt.recall(self:player(), opts)
end
