-- Per-session hunt metrics: how a lure hunt plays (pack per halt, time split,
-- lap time, blocker halts, AoE efficiency, target churn, catch-up teleports,
-- damage taken). Sent with the status broadcast and logged when the hunt ends.

ExpeditionMetrics = ExpeditionMetrics or {}

local nowMs = CombatGeo.nowMs

local function metricsOf(session)
	if not session then
		return nil
	end
	local m = session.metrics
	if not m then
		m = {
			startedMs = nowMs(),
			ticks = { idle = 0, walk = 0, fight = 0, manual = 0 },
			halts = 0,
			haltPack = 0,
			blockerHalts = 0,
			laps = 0,
			lapMs = 0,
			aoeCasts = 0,
			aoeHits = 0,
			targetSwitches = 0,
			hpLost = 0,
			lastHp = {},
		}
		session.metrics = m
	end
	return m
end

local function sessionOf(player)
	if not player then
		return nil
	end
	return ExpeditionManager.getSessionByPlayer(player)
end

--- One AI tick: classify the anchor's activity (its player leading by hand, fighting,
--- walking the route with nothing to attack, or idle in a halt / pace) and accumulate
--- member HP lost.
function ExpeditionMetrics.tick(session, anchor, memberIds)
	local m = metricsOf(session)
	if not m then
		return
	end
	local bucket = "idle"
	if anchor and session.manualIds and session.manualIds[anchor:getId()] then
		bucket = "manual"
	elseif anchor and anchor:getTarget() then
		bucket = "fight"
	elseif session.cave and session.cave.mode == "walk" and not session.cave.parked then
		bucket = "walk"
	end
	m.ticks[bucket] = m.ticks[bucket] + 1
	for _, id in ipairs(memberIds or {}) do
		local member = Player(id)
		if member then
			local hp = member:getHealth()
			local last = m.lastHp[id]
			if last and hp < last then
				m.hpLost = m.hpLost + (last - hp)
			end
			m.lastHp[id] = hp
		end
	end
end

--- Anchor stopped to fight a pack of `pack` visible monsters.
function ExpeditionMetrics.onHalt(session, pack)
	local m = metricsOf(session)
	if not m then
		return
	end
	m.halts = m.halts + 1
	m.haltPack = m.haltPack + math.max(0, tonumber(pack) or 0)
end

--- Anchor stopped because a monster blocked the route.
function ExpeditionMetrics.onBlockerHalt(session)
	local m = metricsOf(session)
	if m then
		m.blockerHalts = m.blockerHalts + 1
	end
end

--- Anchor finished a lap of the cave route in `ms`.
function ExpeditionMetrics.onLap(session, ms)
	local m = metricsOf(session)
	if m then
		m.laps = m.laps + 1
		m.lapMs = m.lapMs + math.max(0, tonumber(ms) or 0)
	end
end

function ExpeditionMetrics.onAreaCast(player, hits)
	local m = metricsOf(sessionOf(player))
	if not m then
		return
	end
	m.aoeCasts = m.aoeCasts + 1
	m.aoeHits = m.aoeHits + math.max(0, tonumber(hits) or 0)
end

function ExpeditionMetrics.onTargetSwitch(player)
	local m = metricsOf(sessionOf(player))
	if m then
		m.targetSwitches = m.targetSwitches + 1
	end
end

local function round1(x)
	return math.floor(x * 10 + 0.5) / 10
end

function ExpeditionMetrics.summary(session)
	local m = session and session.metrics
	if not m then
		return nil
	end
	local minutes = math.max(1 / 60, (nowMs() - m.startedMs) / 60000)
	local manualTicks = m.ticks.manual or 0
	local ticks = m.ticks.idle + m.ticks.walk + m.ticks.fight + manualTicks
	local function pct(n)
		return ticks > 0 and math.floor(n * 100 / ticks + 0.5) or 0
	end
	return {
		minutes = round1(minutes),
		kills = session.kills or 0,
		killsPerMin = round1((session.kills or 0) / minutes),
		spawnBlocks = session.spawnBlocks or 0,
		packPerHalt = m.halts > 0 and round1(m.haltPack / m.halts) or 0,
		halts = m.halts,
		blockerHalts = m.blockerHalts,
		laps = m.laps,
		lapSec = m.laps > 0 and round1(m.lapMs / m.laps / 1000) or 0,
		haltsPerLap = m.laps > 0 and round1(m.halts / m.laps) or 0,
		idlePct = pct(m.ticks.idle),
		walkPct = pct(m.ticks.walk),
		fightPct = pct(m.ticks.fight),
		manualPct = pct(manualTicks),
		aoeHitsPerCast = m.aoeCasts > 0 and round1(m.aoeHits / m.aoeCasts) or 0,
		targetSwitchesPerMin = round1(m.targetSwitches / minutes),
		teleports = session.catchUpTeleports or 0,
		damageTakenPerMin = math.floor(m.hpLost / minutes + 0.5),
	}
end

function ExpeditionMetrics.log(session)
	local s = ExpeditionMetrics.summary(session)
	if not s then
		return
	end
	logger.info(
		"[ExpeditionMetrics] hunt '{}': {} min, {} kills ({}/min), {} spawn blocks, pack/halt {} ({} halts, {} blocker), laps {} ({}s/lap, {} halts/lap), idle/walk/fight/manual {}/{}/{}/{}%, aoe hits/cast {}, target switches/min {}, teleports {}, damage taken/min {}",
		tostring(session.catalog and session.catalog.id),
		s.minutes,
		s.kills,
		s.killsPerMin,
		s.spawnBlocks,
		s.packPerHalt,
		s.halts,
		s.blockerHalts,
		s.laps,
		s.lapSec,
		s.haltsPerLap,
		s.idlePct,
		s.walkPct,
		s.fightPct,
		s.manualPct,
		s.aoeHitsPerCast,
		s.targetSwitchesPerMin,
		s.teleports,
		s.damageTakenPerMin
	)
end
