-- Place weather (extended opcode 113 type "weather").
--
-- Weather is owned by an area key `kind:subareaId` (shared across channels of
-- that place). Clients get it on enter / login, on weather tick changes, and
-- from /weather injects.
--
-- Layers are independent:
--   kind/intensity = precip (clear|rain|snow|storm)
--   fog             = ground mist
--   clouds          = sky cloud cover
--
-- Place tables are biome affinities (bias knobs). Live weather is an episode
-- FSM plus ambient fog/clouds driven by getWorldTime() (same clock as raycast).
PlaceWeather = PlaceWeather or {}

---------------------------------------------------------------------------
-- Place affinities (biome bias — not fixed precip)
---------------------------------------------------------------------------

-- precipFamily: rain | snow | none (arid)
local BY_KIND = {
	city = {
		precipFamily = "rain",
		rainBias = 0.12,
		stormBias = 0.04,
		fogBias = 0.55,
		cloudBias = 0.35,
		quiet = false,
	},
	settlement = {
		precipFamily = "rain",
		rainBias = 0.1,
		stormBias = 0.03,
		fogBias = 0.45,
		cloudBias = 0.3,
		quiet = false,
	},
	hub = {
		precipFamily = "none",
		rainBias = 0,
		stormBias = 0,
		fogBias = 0.1,
		cloudBias = 0.2,
		quiet = true,
	},
	wild = {
		precipFamily = "rain",
		rainBias = 0.45,
		stormBias = 0.18,
		fogBias = 0.4,
		cloudBias = 0.55,
		quiet = false,
	},
	hunt = {
		precipFamily = "rain",
		rainBias = 0.4,
		stormBias = 0.15,
		fogBias = 0.35,
		cloudBias = 0.5,
		quiet = false,
	},
	connector = {
		precipFamily = "rain",
		rainBias = 0.15,
		stormBias = 0.05,
		fogBias = 0.4,
		cloudBias = 0.35,
		quiet = false,
	},
	lobby = {
		precipFamily = "none",
		rainBias = 0,
		stormBias = 0,
		fogBias = 0,
		cloudBias = 0,
		quiet = true,
	},
	raid = {
		precipFamily = "rain",
		rainBias = 0.55,
		stormBias = 0.75,
		fogBias = 0.35,
		cloudBias = 0.85,
		quiet = false,
	},
	arena = {
		precipFamily = "none",
		rainBias = 0,
		stormBias = 0,
		fogBias = 0.05,
		cloudBias = 0.15,
		quiet = true,
	},
	worldboss = {
		precipFamily = "rain",
		rainBias = 0.5,
		stormBias = 0.7,
		fogBias = 0.4,
		cloudBias = 0.8,
		quiet = false,
	},
	soulpit = {
		precipFamily = "none",
		rainBias = 0,
		stormBias = 0,
		fogBias = 0.85,
		cloudBias = 0.25,
		quiet = true,
	},
	house = {
		precipFamily = "none",
		rainBias = 0,
		stormBias = 0,
		fogBias = 0.05,
		cloudBias = 0.2,
		quiet = true,
	},
}

local BY_NAME = {
	{ "svargrond", { precipFamily = "snow", rainBias = 0.55, stormBias = 0.08, fogBias = 0.4, cloudBias = 0.7, windX = 0.35, windY = -0.1 } },
	{ "ankrahmun", { precipFamily = "none", rainBias = 0, stormBias = 0, fogBias = 0.05, cloudBias = 0.2, windX = 0.5, windY = 0.05 } },
	{ "darashia", { precipFamily = "none", rainBias = 0, stormBias = 0, fogBias = 0.05, cloudBias = 0.2, windX = 0.45, windY = 0.05 } },
	{ "venore", { precipFamily = "rain", rainBias = 0.2, stormBias = 0.06, fogBias = 0.95, cloudBias = 0.4 } },
	{ "port hope", { precipFamily = "rain", rainBias = 0.55, stormBias = 0.22, fogBias = 0.45, cloudBias = 0.65 } },
	{ "liberty bay", { precipFamily = "rain", rainBias = 0.45, stormBias = 0.2, fogBias = 0.4, cloudBias = 0.55, windX = 0.4, windY = 0.1 } },
	{ "kazordoon", { precipFamily = "none", rainBias = 0, stormBias = 0, fogBias = 0, cloudBias = 0, quiet = true } },
}

PlaceWeather.BY_SUBAREA = PlaceWeather.BY_SUBAREA or {}

local KEEP_SURFACE = {
	raid = true,
	arena = true,
	worldboss = true,
	soulpit = true,
	lobby = true,
}

---------------------------------------------------------------------------
-- Runtime state
---------------------------------------------------------------------------

-- Cached affinity per area key.
local affinityByArea = {}
-- Per-area weather machine: phase, targets, timers (tibia minutes), boosts.
local machineByArea = {}
-- Last weather fingerprint sent to each player (dedupe).
local lastSent = {}

-- Think interval (real ms). ~30s ≈ 12 tibia minutes at 2.5s/min.
PlaceWeather.THINK_MS = 30000

local PHASE = {
	clear = "clear",
	building = "building",
	rain = "rain",
	snow = "snow",
	storm = "storm",
	clearing = "clearing",
}

---------------------------------------------------------------------------
-- Helpers
---------------------------------------------------------------------------

local function shallowCopy(t)
	local out = {}
	if type(t) ~= "table" then
		return out
	end
	for k, v in pairs(t) do
		out[k] = v
	end
	return out
end

local function clamp01(v)
	v = tonumber(v) or 0
	if v < 0 then
		return 0
	end
	if v > 1 then
		return 1
	end
	return v
end

local function lerp(a, b, t)
	return a + (b - a) * t
end

local function worldMinutes()
	local t = getWorldTime and getWorldTime() or 0
	return math.floor(tonumber(t) or 0) % 1440
end

--- Soft bump peaking at `center` with half-width `half` (tibia minutes).
local function todBump(minutes, center, half)
	local d = math.abs(minutes - center)
	if d > 720 then
		d = 1440 - d
	end
	if d >= half then
		return 0
	end
	return 1 - (d / half)
end

local function isNightMinutes(minutes)
	-- Align with raycast sun window ~06:00–19:30 for ambient (not engine SUNSET light ramp).
	return minutes < 360 or minutes >= 1170
end

function PlaceWeather.areaKey(desc)
	if type(desc) ~= "table" then
		return nil
	end
	local kind = tostring(desc.kind or "")
	if kind == "" then
		return nil
	end
	local sid = tonumber(desc.subareaId) or 0
	return kind .. ":" .. tostring(sid)
end

function PlaceWeather.areaKeyForPlayer(player)
	if not player or not InstanceWorld then
		return nil
	end
	return PlaceWeather.areaKey(InstanceWorld.describeCurrent(player))
end

local function nameAffinity(name)
	name = string.lower(tostring(name or ""))
	if name == "" then
		return nil
	end
	for _, entry in ipairs(BY_NAME) do
		if string.find(name, entry[1], 1, true) then
			return entry[2]
		end
	end
	return nil
end

local function resolveAffinity(desc)
	if type(desc) ~= "table" then
		return shallowCopy(BY_KIND.wild)
	end
	local key = PlaceWeather.areaKey(desc)
	if key and affinityByArea[key] then
		return shallowCopy(affinityByArea[key])
	end

	local kind = tostring(desc.kind or "")
	local sid = tonumber(desc.subareaId) or 0
	local profile = nil
	if sid > 0 and PlaceWeather.BY_SUBAREA[sid] then
		profile = PlaceWeather.BY_SUBAREA[sid]
	end
	profile = profile or nameAffinity(desc.name) or BY_KIND[kind] or BY_KIND.wild
	profile = shallowCopy(profile)
	profile.precipFamily = profile.precipFamily or "rain"
	profile.rainBias = clamp01(profile.rainBias or 0.3)
	profile.stormBias = clamp01(profile.stormBias or 0.1)
	profile.fogBias = clamp01(profile.fogBias or 0.35)
	profile.cloudBias = clamp01(profile.cloudBias or 0.4)
	profile.quiet = profile.quiet and true or false
	profile.windX = tonumber(profile.windX) or 0
	profile.windY = tonumber(profile.windY) or 0
	if key then
		affinityByArea[key] = shallowCopy(profile)
	end
	return profile
end

---------------------------------------------------------------------------
-- Ambient TOD curves
---------------------------------------------------------------------------

local function ambientFog(affinity, minutes)
	local dawn = todBump(minutes, 390, 150) -- ~05:00–08:30 peak ~06:30
	local dusk = todBump(minutes, 1140, 90) -- ~17:30–20:30
	local night = isNightMinutes(minutes) and 0.35 or 0.08
	local raw = math.max(dawn * 0.85, dusk * 0.35, night)
	return clamp01(raw * (affinity.fogBias or 0.35))
end

local function ambientClouds(affinity, minutes, phase)
	local day = 1 - math.abs((minutes - 780) / 780) -- mild midday dip
	local base = 0.15 + 0.35 * day
	if isNightMinutes(minutes) then
		base = 0.25
	end
	local lift = 0
	if phase == PHASE.building then
		lift = 0.45
	elseif phase == PHASE.rain or phase == PHASE.snow then
		lift = 0.55
	elseif phase == PHASE.storm then
		lift = 0.75
	elseif phase == PHASE.clearing then
		lift = 0.3
	end
	return clamp01((base * (affinity.cloudBias or 0.4)) + lift * (0.4 + 0.6 * (affinity.cloudBias or 0.4)))
end

local function ambientWind(affinity, phase)
	local wx = tonumber(affinity.windX) or 0
	local wy = tonumber(affinity.windY) or 0
	if phase == PHASE.storm then
		return wx * 1.4 + 0.25, wy * 1.4 - 0.05
	end
	if phase == PHASE.rain or phase == PHASE.snow or phase == PHASE.building then
		return wx * 1.15 + 0.12, wy * 1.15
	end
	return wx, wy
end

---------------------------------------------------------------------------
-- Episode machine
---------------------------------------------------------------------------

local function defaultMachine(affinity)
	return {
		phase = PHASE.clear,
		intensity = 0,
		targetIntensity = 0,
		phaseRemaining = 0, -- tibia minutes left in current phase (0 = idle clear)
		fogBoost = 0,
		fogBoostRemaining = 0,
		cloudsBoost = 0,
		cloudsBoostRemaining = 0,
		forced = false, -- GOD inject
		lastWorldMinutes = nil,
		affinitySnapshot = shallowCopy(affinity),
	}
end

local function ensureMachine(areaKey, desc)
	if not areaKey then
		return nil
	end
	local m = machineByArea[areaKey]
	if m then
		return m
	end
	local affinity = resolveAffinity(desc or {})
	m = defaultMachine(affinity)
	m.lastWorldMinutes = worldMinutes()
	machineByArea[areaKey] = m
	return m
end

local function precipKindForPhase(phase, affinity)
	if phase == PHASE.storm then
		return "storm"
	end
	if phase == PHASE.snow then
		return "snow"
	end
	if phase == PHASE.rain then
		return "rain"
	end
	if phase == PHASE.building or phase == PHASE.clearing then
		-- Building / clearing: no precip yet (or fading); intensity may still show light rain if clearing from rain.
		if phase == PHASE.clearing and (affinity.precipFamily == "snow") then
			return "snow"
		end
		if phase == PHASE.clearing then
			return "rain"
		end
		return "clear"
	end
	return "clear"
end

local function familyPrecip(affinity)
	if affinity.precipFamily == "snow" then
		return PHASE.snow
	end
	return PHASE.rain
end

local function randomBetween(a, b)
	a, b = math.floor(a), math.floor(b)
	if b <= a then
		return a
	end
	return math.random(a, b)
end

--- Elapsed tibia minutes since last tick (handles day wrap).
local function elapsedSince(m, minutes)
	if m.lastWorldMinutes == nil then
		m.lastWorldMinutes = minutes
		return 0
	end
	local d = (minutes - m.lastWorldMinutes) % 1440
	m.lastWorldMinutes = minutes
	-- Cap so a /time scrub does not skip an entire episode in one think.
	if d > 60 then
		d = 12
	end
	return d
end

--- TOD weights for starting / escalating weather (0–1-ish scalars).
local function todWeights(minutes)
	local dawn = todBump(minutes, 390, 150)
	local midday = todBump(minutes, 780, 240)
	local stormWindow = todBump(minutes, 960, 240) -- afternoon–early evening
	local night = isNightMinutes(minutes) and 1 or 0
	return {
		fog = 0.4 + dawn * 0.8,
		shower = 0.15 + midday * 0.55 + dawn * 0.2,
		storm = 0.05 + stormWindow * 0.85 + (1 - night) * 0.05,
		quietNight = 0.3 + night * 0.5,
	}
end

local function intensityBand(phase)
	if phase == PHASE.building then
		return 0, 0
	end
	if phase == PHASE.rain or phase == PHASE.snow then
		return 0.25, 0.6
	end
	if phase == PHASE.storm then
		return 0.65, 0.9
	end
	if phase == PHASE.clearing then
		return 0.05, 0.25
	end
	return 0, 0
end

--- Enter a phase. When `intensity` is set, snap current intensity (inject / forced);
--- otherwise ease from the current value toward a random band target.
local function enterPhase(m, phase, _minutes, durationMin, intensity)
	m.phase = phase
	m.phaseRemaining = math.max(0, durationMin or 0)
	local lo, hi = intensityBand(phase)
	if intensity ~= nil then
		m.targetIntensity = clamp01(intensity)
		m.intensity = m.targetIntensity
	else
		m.targetIntensity = clamp01(lerp(lo, hi, math.random()))
	end
	if phase == PHASE.clear then
		m.targetIntensity = 0
		m.intensity = 0
		m.phaseRemaining = 0
	end
end

local function rollStart(affinity, minutes)
	if affinity.quiet or affinity.precipFamily == "none" then
		return nil
	end
	local w = todWeights(minutes)
	local rainChance = affinity.rainBias * w.shower * (1 - w.quietNight * 0.4)
	local stormChance = affinity.stormBias * w.storm
	-- Per-think probability (think ≈ 12 tibia min); scale down so episodes are occasional.
	local scale = 0.18
	local r = math.random()
	if r < stormChance * scale * 0.45 then
		-- Front: building then storm, or direct storm with short building.
		return "front"
	end
	if r < (stormChance * scale * 0.45) + (rainChance * scale) then
		return "shower"
	end
	return nil
end

local function tickMachine(_areaKey, m, minutes)
	local affinity = m.affinitySnapshot or BY_KIND.wild
	local dt = elapsedSince(m, minutes)

	if dt > 0 then
		if (m.fogBoostRemaining or 0) > 0 then
			m.fogBoostRemaining = math.max(0, m.fogBoostRemaining - dt)
			if m.fogBoostRemaining <= 0 then
				m.fogBoost = 0
			end
		end
		if (m.cloudsBoostRemaining or 0) > 0 then
			m.cloudsBoostRemaining = math.max(0, m.cloudsBoostRemaining - dt)
			if m.cloudsBoostRemaining <= 0 then
				m.cloudsBoost = 0
			end
		end
		if m.phase ~= PHASE.clear and (m.phaseRemaining or 0) > 0 then
			m.phaseRemaining = math.max(0, m.phaseRemaining - dt)
		end
	end

	-- Ease intensity toward target each think.
	local step = 0.18
	if m.intensity < m.targetIntensity then
		m.intensity = math.min(m.targetIntensity, m.intensity + step)
	elseif m.intensity > m.targetIntensity then
		m.intensity = math.max(m.targetIntensity, m.intensity - step)
	end

	if m.phase == PHASE.clear then
		local start = rollStart(affinity, minutes)
		if start == "front" then
			enterPhase(m, PHASE.building, minutes, randomBetween(8, 16))
			m._nextAfterBuild = PHASE.storm
		elseif start == "shower" then
			enterPhase(m, PHASE.building, minutes, randomBetween(8, 20))
			m._nextAfterBuild = familyPrecip(affinity)
		end
		return
	end

	local phaseDone = (m.phaseRemaining or 0) <= 0
	if not phaseDone then
		if (m.phase == PHASE.rain or m.phase == PHASE.snow) and not m.forced then
			local w = todWeights(minutes)
			if math.random() < affinity.stormBias * w.storm * 0.12 then
				enterPhase(m, PHASE.storm, minutes, randomBetween(8, 20))
			end
		end
		return
	end

	if m.phase == PHASE.building then
		local next = m._nextAfterBuild or familyPrecip(affinity)
		m._nextAfterBuild = nil
		local inj = m._injectIntensity
		m._injectIntensity = nil
		-- Storm cores must outlive ≥2 think ticks (~24 tibia min) or scrub never sees lightning.
		if next == PHASE.storm then
			local dur = m.forced and randomBetween(30, 45) or randomBetween(24, 40)
			local stormI = inj or lerp(0.65, 0.9, math.random())
			enterPhase(m, PHASE.storm, minutes, dur, stormI)
		else
			local dur = m.forced and randomBetween(25, 40) or randomBetween(15, 40)
			enterPhase(m, next, minutes, dur, inj)
		end
		return
	end

	if m.phase == PHASE.storm then
		-- Forced scrub: always clear-down (do not collapse into plain rain).
		if m.forced or math.random() >= 0.65 or affinity.precipFamily == "none" then
			enterPhase(m, PHASE.clearing, minutes, randomBetween(10, 25), math.max(0.1, m.intensity * 0.4))
			m.forced = false
		else
			enterPhase(m, familyPrecip(affinity), minutes, randomBetween(10, 25))
		end
		return
	end

	if m.phase == PHASE.rain or m.phase == PHASE.snow then
		enterPhase(m, PHASE.clearing, minutes, randomBetween(10, 25), math.max(0.08, m.intensity * 0.35))
		m.forced = false
		return
	end

	if m.phase == PHASE.clearing then
		enterPhase(m, PHASE.clear, minutes, 0)
		m.forced = false
		return
	end
end

---------------------------------------------------------------------------
-- Compose payload
---------------------------------------------------------------------------

local function composePayload(affinity, m, minutes)
	m = m or defaultMachine(affinity)
	local phase = m.phase or PHASE.clear
	local fog = ambientFog(affinity, minutes)
	local clouds = ambientClouds(affinity, minutes, phase)
	fog = clamp01(fog + (m.fogBoost or 0))
	clouds = clamp01(clouds + (m.cloudsBoost or 0))
	local wx, wy = ambientWind(affinity, phase)
	local kind = precipKindForPhase(phase, affinity)
	local intensity = clamp01(m.intensity or 0)
	if kind == "clear" then
		intensity = 0
	end
	-- Building: clouds only.
	if phase == PHASE.building then
		kind = "clear"
		intensity = 0
	end
	local transitionMs = 2000
	if phase == PHASE.storm then
		transitionMs = 1500
	elseif phase == PHASE.clearing or phase == PHASE.building then
		transitionMs = 2500
	end
	return {
		type = "weather",
		kind = kind,
		intensity = intensity,
		fog = fog,
		clouds = clouds,
		windX = wx,
		windY = wy,
		precipSoundId = 0,
		transitionMs = transitionMs,
	}
end

local function fingerprint(payload)
	return string.format("%s:%.2f:%.2f:%.2f:%.2f:%.2f:%d", payload.kind, payload.intensity or 0, payload.fog or 0,
		payload.clouds or 0, payload.windX or 0, payload.windY or 0, payload.precipSoundId or 0)
end

local function descFromAreaKey(areaKey)
	local kind, sid = tostring(areaKey or ""):match("^([^:]+):(%d+)$")
	if not kind then
		return nil
	end
	return {
		kind = kind,
		subareaId = tonumber(sid) or 0,
		name = InstanceWorld and InstanceWorld.subareaName(tonumber(sid) or 0) or nil,
	}
end

function PlaceWeather.payloadFor(desc, player, _period)
	local key = PlaceWeather.areaKey(desc)
	local affinity = resolveAffinity(desc)
	local kind = desc and tostring(desc.kind or "") or ""
	if player and not KEEP_SURFACE[kind] then
		local pos = player:getPosition()
		if pos and (tonumber(pos.z) or 7) > 7 then
			return {
				type = "weather",
				kind = "clear",
				intensity = 0,
				fog = 0,
				clouds = 0,
				windX = 0,
				windY = 0,
				precipSoundId = 0,
				transitionMs = 1500,
			}
		end
	end
	local m = key and ensureMachine(key, desc) or defaultMachine(affinity)
	return composePayload(affinity, m, worldMinutes())
end

function PlaceWeather.selection(player, desc, period)
	if desc == nil and InstanceWorld then
		desc = InstanceWorld.describeCurrent(player)
	end
	return PlaceWeather.payloadFor(desc, player, period)
end

function PlaceWeather.machineOf(player)
	local key = PlaceWeather.areaKeyForPlayer(player)
	return key and machineByArea[key] or nil
end

function PlaceWeather.liveOf(player)
	-- Back-compat: "live" means non-clear episode.
	local m = PlaceWeather.machineOf(player)
	if not m or m.phase == PHASE.clear then
		return nil
	end
	return m
end

function PlaceWeather.areaInfo(player)
	if not player or not InstanceWorld then
		return nil
	end
	local desc = InstanceWorld.describeCurrent(player)
	local key = PlaceWeather.areaKey(desc)
	if not key then
		return nil
	end
	local m = ensureMachine(key, desc)
	local affinity = resolveAffinity(desc)
	local minutes = worldMinutes()
	return {
		key = key,
		kind = desc and desc.kind or nil,
		subareaId = desc and tonumber(desc.subareaId) or 0,
		name = desc and desc.name or key,
		live = m.phase ~= PHASE.clear,
		phase = m.phase,
		phaseRemaining = m.phaseRemaining or 0,
		affinity = affinity,
		worldMinutes = minutes,
		payload = PlaceWeather.payloadFor(desc, player),
	}
end

---------------------------------------------------------------------------
-- Inject / boost (GOD + scripts)
---------------------------------------------------------------------------

function PlaceWeather.injectEpisode(areaKey, precipKind, intensity)
	local desc = descFromAreaKey(areaKey)
	if not desc then
		return false, "Invalid area."
	end
	local affinity = resolveAffinity(desc)
	local m = ensureMachine(areaKey, desc)
	m.affinitySnapshot = shallowCopy(affinity)
	local minutes = worldMinutes()
	m.lastWorldMinutes = minutes
	precipKind = string.lower(tostring(precipKind or "rain"))
	local lo, hi = 0.35, 0.7
	if precipKind == "storm" then
		lo, hi = 0.65, 0.9
	elseif precipKind == "snow" then
		lo, hi = 0.3, 0.65
	end
	local i = intensity
	if i == nil then
		i = lerp(lo, hi, 0.55)
	end
	i = clamp01(i)
	-- Keep inject intensity inside the kind's natural band (1.0 scrub → band top).
	if i < lo * 0.85 then
		i = lo * 0.85
	elseif i > hi then
		i = hi
	end

	m._nextAfterBuild = nil
	m._injectIntensity = nil

	if precipKind == "storm" then
		-- Scrub / inject: enter storm immediately at full intensity (building skipped).
		-- Duration ≥ ~3 think ticks so client lightning (needs intensity > 0.35) is visible.
		enterPhase(m, PHASE.storm, minutes, randomBetween(30, 45), i)
		m.forced = true
		return true
	end

	if precipKind == "snow" or precipKind == "rain" then
		local phase = precipKind == "snow" and PHASE.snow or PHASE.rain
		if affinity.precipFamily == "snow" and precipKind == "rain" then
			phase = PHASE.snow
		end
		enterPhase(m, phase, minutes, randomBetween(25, 40), i)
		m.forced = true
		return true
	end

	return false, "Unknown precip kind."
end

function PlaceWeather.boostLayer(areaKey, layer, intensity, durationMin)
	local desc = descFromAreaKey(areaKey)
	if not desc then
		return false, "Invalid area."
	end
	local m = ensureMachine(areaKey, desc)
	local minutes = worldMinutes()
	intensity = clamp01(intensity ~= nil and intensity or 0.65)
	durationMin = durationMin or randomBetween(15, 40)
	if layer == "fog" then
		m.fogBoost = math.max(m.fogBoost or 0, intensity)
		m.fogBoostRemaining = math.max(m.fogBoostRemaining or 0, durationMin)
		m.lastWorldMinutes = m.lastWorldMinutes or minutes
		return true
	end
	if layer == "clouds" then
		m.cloudsBoost = math.max(m.cloudsBoost or 0, intensity)
		m.cloudsBoostRemaining = math.max(m.cloudsBoostRemaining or 0, durationMin)
		m.lastWorldMinutes = m.lastWorldMinutes or minutes
		return true
	end
	return false, "Unknown layer."
end

function PlaceWeather.beginClearDown(areaKey)
	local desc = descFromAreaKey(areaKey)
	if not desc then
		return false, "Invalid area."
	end
	local m = ensureMachine(areaKey, desc)
	local minutes = worldMinutes()
	m._nextAfterBuild = nil
	m._injectIntensity = nil
	m.forced = true
	m.fogBoost = 0
	m.fogBoostRemaining = 0
	m.cloudsBoost = 0
	m.cloudsBoostRemaining = 0
	if m.phase == PHASE.clear and (m.intensity or 0) < 0.05 then
		enterPhase(m, PHASE.clear, minutes, 0)
		return true
	end
	enterPhase(m, PHASE.clearing, minutes, randomBetween(8, 16), math.max(0.05, (m.intensity or 0) * 0.3))
	return true
end

---------------------------------------------------------------------------
-- Send / broadcast
---------------------------------------------------------------------------

function PlaceWeather.send(player, desc, period, force)
	if not player or not IdleUtil or not IdleUtil.jsonSender then
		return false
	end
	if desc == nil and InstanceWorld then
		desc = InstanceWorld.describeCurrent(player)
	end
	local key = PlaceWeather.areaKey(desc)
	if key then
		ensureMachine(key, desc)
	end
	local payload = PlaceWeather.payloadFor(desc, player, period)
	local pid = player:getId()
	local fp = fingerprint(payload)
	if not force and lastSent[pid] == fp then
		return true
	end
	local send = IdleUtil.jsonSender(ExpeditionConfig and ExpeditionConfig.OPCODE or 113)
	if not send(player, payload) then
		return false
	end
	lastSent[pid] = fp
	return true
end

function PlaceWeather.broadcastArea(areaKey, period)
	if not areaKey then
		return 0
	end
	local n = 0
	for _, other in ipairs(Game.getPlayers() or {}) do
		if PlaceWeather.areaKeyForPlayer(other) == areaKey then
			if PlaceWeather.send(other, nil, period, true) then
				n = n + 1
			end
		end
	end
	return n
end

function PlaceWeather.applyForPlayerArea(player, fields)
	if not player then
		return nil, "Invalid player."
	end
	local info = PlaceWeather.areaInfo(player)
	if not info or not info.key then
		return nil, "You are not in a place that has weather."
	end
	fields = fields or {}
	if fields.clearAll and fields.resetBase then
		PlaceWeather.beginClearDown(info.key)
	elseif fields.kind and fields.kind ~= "clear" then
		local ok, err = PlaceWeather.injectEpisode(info.key, fields.kind, fields.intensity)
		if not ok then
			return nil, err
		end
	elseif fields.fog ~= nil and fields.kind == nil and fields.clouds == nil then
		PlaceWeather.boostLayer(info.key, "fog", fields.fog)
	elseif fields.clouds ~= nil and fields.kind == nil then
		PlaceWeather.boostLayer(info.key, "clouds", fields.clouds)
	elseif fields.clearAll then
		PlaceWeather.beginClearDown(info.key)
	else
		-- Mixed / wind-only: boost layers if present, else no-op compose.
		if fields.fog ~= nil then
			PlaceWeather.boostLayer(info.key, "fog", fields.fog)
		end
		if fields.clouds ~= nil then
			PlaceWeather.boostLayer(info.key, "clouds", fields.clouds)
		end
		if fields.kind == "clear" then
			PlaceWeather.beginClearDown(info.key)
		end
	end
	local n = PlaceWeather.broadcastArea(info.key)
	return n, info
end

function PlaceWeather.forget(player)
	if player then
		lastSent[player:getId()] = nil
	end
end

function PlaceWeather.refreshOnline(period)
	for _, player in ipairs(Game.getPlayers() or {}) do
		PlaceWeather.send(player, nil, period, true)
	end
end

--- Advance all known area machines; broadcast when fingerprint changes.
function PlaceWeather.think()
	local minutes = worldMinutes()
	-- Ensure online players' areas have a machine before ticking.
	for _, player in ipairs(Game.getPlayers() or {}) do
		local key = PlaceWeather.areaKeyForPlayer(player)
		if key then
			local desc = InstanceWorld and InstanceWorld.describeCurrent(player) or descFromAreaKey(key)
			ensureMachine(key, desc)
		end
	end
	local touched = {}
	for areaKey, m in pairs(machineByArea) do
		local aff = m.affinitySnapshot or BY_KIND.wild
		local before = fingerprint(composePayload(aff, m, minutes))
		tickMachine(areaKey, m, minutes)
		local after = fingerprint(composePayload(aff, m, minutes))
		if before ~= after then
			touched[areaKey] = true
		end
	end
	for areaKey in pairs(touched) do
		PlaceWeather.broadcastArea(areaKey)
	end
end

function PlaceWeather.seedAreas()
	local n = 0
	if InstanceWorld and InstanceWorld.citiesBySubareaId then
		for subareaId, city in pairs(InstanceWorld.citiesBySubareaId) do
			local kind = select(1, InstanceWorld.areaIdentity(city)) or "city"
			local desc = {
				kind = kind,
				subareaId = tonumber(subareaId) or 0,
				name = city.name or InstanceWorld.subareaName(subareaId),
			}
			local key = PlaceWeather.areaKey(desc)
			if key then
				resolveAffinity(desc)
				ensureMachine(key, desc)
				n = n + 1
			end
		end
	end
	if InstanceWorld and InstanceWorld.HUB_ADVENTURERS then
		local hubId = Instance.subareaId(InstanceWorld.HUB_ADVENTURERS)
		local desc = {
			kind = "hub",
			subareaId = hubId,
			name = "Adventurers' Guild",
		}
		local key = PlaceWeather.areaKey(desc)
		resolveAffinity(desc)
		if key then
			ensureMachine(key, desc)
		end
		n = n + 1
	end
	logger.info("[PlaceWeather] seeded {} area place affinities", n)
	return n
end

-- Back-compat aliases.
function PlaceWeather.overrideOf(player)
	return PlaceWeather.liveOf(player)
end

function PlaceWeather.broadcastOverride(player, fields)
	local n = PlaceWeather.applyForPlayerArea(player, fields)
	return n or 0
end

function PlaceWeather.setOverride(player, fields)
	PlaceWeather.applyForPlayerArea(player, fields)
end

function PlaceWeather.clearOverride(player)
	PlaceWeather.applyForPlayerArea(player, { clearAll = true, resetBase = true, transitionMs = 800 })
end

-- Legacy no-ops mapped onto machine.
function PlaceWeather.setAreaLive(areaKey, fields)
	fields = fields or {}
	if fields.clearAll and fields.resetBase then
		return PlaceWeather.beginClearDown(areaKey)
	end
	if fields.kind and fields.kind ~= "clear" then
		return PlaceWeather.injectEpisode(areaKey, fields.kind, fields.intensity)
	end
	if fields.fog then
		PlaceWeather.boostLayer(areaKey, "fog", fields.fog)
	end
	if fields.clouds then
		PlaceWeather.boostLayer(areaKey, "clouds", fields.clouds)
	end
	return true
end

function PlaceWeather.clearAreaLive(areaKey)
	return PlaceWeather.beginClearDown(areaKey)
end
