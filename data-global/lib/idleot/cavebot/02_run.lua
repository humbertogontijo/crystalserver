-- Cavebot runs: the state a party anchor walks a cave route with. An expedition
-- session is a run in place (session.cave, session.engaged, ...); an open-world run
-- (CavebotService) is a plain table with `open = true`.
--
-- run = {
--   route (open runs; expeditions read ExpeditionConfig.caveRoute(run.catalog)),
--   lure, cave, tracked, engaged, releasedUntil, lastKillAt, kills, metrics,
--   manualIds (id -> true: paused members), pauseReasons (id -> reason), anchorPlayerId,
--   open, id, instanceId, ids, routeSource, huntName (open runs only),
-- }

Cavebot = Cavebot or {}

-- Party anchor: lower rank wins (knight → paladin → monk → anyone else).
Cavebot.ANCHOR_VOCATION_RANK = {
	knight = 1,
	paladin = 2,
	monk = 3,
	other = 4,
}

--- Vocation priority rank for anchor selection (lower = preferred).
function Cavebot.anchorVocationRank(player)
	local ranks = Cavebot.ANCHOR_VOCATION_RANK
	local vocation = player and player:getVocation()
	if not vocation then
		return ranks.other
	end
	local baseId = vocation:getBaseId()
	if baseId == VOCATION.BASE_ID.KNIGHT then
		return ranks.knight
	end
	if baseId == VOCATION.BASE_ID.PALADIN then
		return ranks.paladin
	end
	if VOCATION.BASE_ID.MONK and baseId == VOCATION.BASE_ID.MONK then
		return ranks.monk
	end
	return ranks.other
end

--- Best anchor among `players` (non-empty): vocation rank, then highest max HP, then lowest id.
function Cavebot.bestAnchor(players)
	local best = players[1]
	local bestRank = Cavebot.anchorVocationRank(best)
	local bestHp = best:getMaxHealth() or 0
	local bestId = best:getId()
	for i = 2, #players do
		local p = players[i]
		local rank = Cavebot.anchorVocationRank(p)
		local hp = p:getMaxHealth() or 0
		local id = p:getId()
		if rank < bestRank or (rank == bestRank and hp > bestHp) or (rank == bestRank and hp == bestHp and id < bestId) then
			best, bestRank, bestHp, bestId = p, rank, hp, id
		end
	end
	return best
end

function Cavebot.isOpen(run)
	return run ~= nil and run.open == true
end

function Cavebot.routeOf(run)
	if not run then
		return nil
	end
	if run.route then
		return run.route
	end
	return run.catalog and ExpeditionConfig and ExpeditionConfig.caveRoute(run.catalog) or nil
end

function Cavebot.memberIds(run)
	if not run then
		return {}
	end
	if run.open then
		return run.ids or {}
	end
	return ExpeditionManager.sessionMemberIds(run) or {}
end

--- Member ids as a set (id -> true).
function Cavebot.memberSet(run)
	local set = {}
	for _, id in ipairs(Cavebot.memberIds(run)) do
		set[id] = true
	end
	return set
end

function Cavebot.anchorOf(run)
	if not run then
		return nil
	end
	if run.open then
		local anchor = run.anchorPlayerId and Player(run.anchorPlayerId)
		return anchor and anchor:getHealth() > 0 and anchor or nil
	end
	return ExpeditionConfig.getAnchorPlayer and ExpeditionConfig.getAnchorPlayer(run) or nil
end

--- Walker state changed (mode, manual, kills): refresh the members' status.
function Cavebot.notify(run)
	if not run then
		return
	end
	if not run.open and ExpeditionManager and ExpeditionManager.broadcastStatus then
		ExpeditionManager.broadcastStatus(run)
	end
	if CavebotProtocol then
		CavebotProtocol.sendRun(run)
	end
end

--- The run walking a cave route `player` is in: their expedition session (with a cave),
--- else their open-world run.
function Cavebot.runOfPlayer(player)
	if not player then
		return nil
	end
	local session = ExpeditionManager and ExpeditionManager.getSessionByPlayer and ExpeditionManager.getSessionByPlayer(player)
	if session and session.cave then
		return session
	end
	return CavebotService and CavebotService.runOfPlayer(player) or nil
end
