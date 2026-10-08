-- Game-state gauges for Prometheus (scraped by deploy/metrics). No-op unless
-- the server is built with FEATURE_METRICS and an exporter is enabled.

local EXPEDITION_ROLES = { "monster", "boss", "arena" }

local function exporterEnabled()
	return configManager.getBoolean(configKeys.METRICS_ENABLE_PROMETHEUS) or configManager.getBoolean(configKeys.METRICS_ENABLE_OSTREAM)
end

local function reportPlayers()
	local connected, headless = 0, 0
	for _, player in ipairs(Game.getPlayers()) do
		if player:isHeadless() then
			headless = headless + 1
		else
			connected = connected + 1
		end
	end
	metrics.setGauge("game_players", connected, { client = "connected" })
	metrics.setGauge("game_players", headless, { client = "headless" })
end

local function reportExpeditions()
	local byRole = ExpeditionManager.stats().byRole
	for _, role in ipairs(EXPEDITION_ROLES) do
		byRole[role] = byRole[role] or 0
	end
	for role, count in pairs(byRole) do
		metrics.setGauge("game_expeditions", count, { role = role })
	end
end

local gauges = GlobalEvent("IdleotMetricsGauges")

function gauges.onThink(interval)
	if not exporterEnabled() then
		return true
	end
	reportPlayers()
	metrics.setGauge("game_monsters", Game.getMonsterCount())
	metrics.setGauge("game_npcs", Game.getNpcCount())
	reportExpeditions()
	return true
end

gauges:interval(10000)
gauges:register()
