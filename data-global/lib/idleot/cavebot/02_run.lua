-- Cavebot runs: the state a party anchor walks a cave route with. An expedition
-- session is a run in place (session.cave, session.engaged, ...); an open-world run
-- (CavebotService) is a plain table with `open = true`.
--
-- run = {
--   host, scope, lure, cave, tracked, engaged, releasedUntil, lastKillAt, kills, metrics,
--   manualIds (id -> true: paused members), pauseReasons (id -> reason), anchorPlayerId,
--   open, id, instanceId, ids, route, routeSource, huntName (open runs only),
-- }
--
-- run.host: what the walker needs from the system that owns the run (open-world runs
-- carry their own; expedition sessions use Cavebot.sessionHost):
--   memberIds(run) -> ids          anchor(run) -> player|nil      route(run) -> route|nil
--   alive(run) -> bool             walks(run) -> bool (the walker runs this tick)
--   notify(run)                    walker state changed (beyond CavebotProtocol.sendRun)
--   onStart(run)                   a walk started
--   priorityTarget(run) -> monster|nil   halts the walk on sight, detoured to (Fiendish)
--   onPauseChange(run, player, reason, prev)
--   directives(run) -> opts        Cavebot.syncDirectives options
--   adopt                          true: track only monsters that target a member
--   metrics = { tick(run, anchor, ids), onLap(run, ms), onHalt(run, visible), onBlockerHalt(run) }
-- Every field but memberIds / anchor / route is optional.

Cavebot = Cavebot or {}

--- The run's host (open-world runs carry their own; sessions use Cavebot.sessionHost).
function Cavebot.hostOf(run)
	return run.host or Cavebot.sessionHost
end
local hostOf = Cavebot.hostOf

--- `run.host.metrics[name](run, ...)` when the host records it.
function Cavebot.metric(run, name, ...)
	local metrics = hostOf(run).metrics
	local fn = metrics and metrics[name]
	if fn then
		fn(run, ...)
	end
end

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

--- Best living (online, HP > 0) player among `ids`, skipping ids flagged in `skip`.
function Cavebot.electAnchor(ids, skip)
	local candidates = {}
	for _, id in ipairs(ids) do
		local player = not (skip and skip[id]) and Player(id)
		if player and player:getHealth() > 0 then
			candidates[#candidates + 1] = player
		end
	end
	return candidates[1] and Cavebot.bestAnchor(candidates) or nil
end

function Cavebot.isOpen(run)
	return run ~= nil and run.open == true
end

function Cavebot.routeOf(run)
	return run and hostOf(run).route(run) or nil
end

function Cavebot.memberIds(run)
	return run and hostOf(run).memberIds(run) or {}
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
	return run and hostOf(run).anchor(run) or nil
end

--- Walker state changed (mode, manual, kills): refresh the members' status.
function Cavebot.notify(run)
	if not run then
		return
	end
	local host = hostOf(run)
	if host.notify then
		host.notify(run)
	end
	CavebotProtocol.sendRun(run)
end

--- The run walking a cave route `player` is in: their expedition session (with a cave),
--- else their open-world run.
function Cavebot.runOfPlayer(player)
	if not player then
		return nil
	end
	local session = ExpeditionManager.getSessionByPlayer(player)
	if session and session.cave then
		return session
	end
	return CavebotService.runOfPlayer(player) or nil
end
