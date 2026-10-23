-- Place climate (extended opcode 113 type "climate"), sent with instance identity
-- the same way PlaceSound sends ambience beds.
--
-- Layers are independent:
--   kind/intensity = precip (clear|rain|snow|storm)
--   fog             = ground mist (river/swamp) — not the same as clouds
--   clouds          = sky cloud cover — scrolls with wind
PlaceClimate = PlaceClimate or {}

-- precip, intensity, fog, clouds, optional wind; day/night pick precip + layer amounts.
local BY_KIND = {
	city = { precip = "clear", intensity = 0, fog = 0.1, fogNight = 0.35, clouds = 0.25, cloudsNight = 0.4 },
	settlement = { precip = "clear", intensity = 0, fog = 0.1, fogNight = 0.3, clouds = 0.2, cloudsNight = 0.35 },
	hub = { precip = "clear", intensity = 0, fog = 0, clouds = 0.15, cloudsNight = 0.25 },
	wild = { precip = "rain", intensity = 0.5, precipNight = "clear", fogNight = 0.25, clouds = 0.55, cloudsNight = 0.45 },
	hunt = { precip = "rain", intensity = 0.45, precipNight = "clear", fogNight = 0.2, clouds = 0.5, cloudsNight = 0.4 },
	connector = { precip = "clear", intensity = 0, fogNight = 0.25, clouds = 0.3, cloudsNight = 0.4 },
	lobby = { precip = "clear", intensity = 0, fog = 0, clouds = 0 },
	raid = { precip = "storm", intensity = 0.75, fog = 0.15, clouds = 0.85 },
	arena = { precip = "clear", intensity = 0, fog = 0, clouds = 0.1 },
	worldboss = { precip = "storm", intensity = 0.7, fog = 0.2, clouds = 0.8 },
	soulpit = { precip = "clear", intensity = 0, fog = 0.5, clouds = 0.2 },
}

local BY_NAME = {
	-- Sky clouds + snow precip (independent).
	{ "svargrond", { precip = "snow", intensity = 0.65, fog = 0.15, clouds = 0.7, windX = 0.35, windY = -0.1 } },
	-- Desert: little fog, some high clouds + wind.
	{ "ankrahmun", { precip = "clear", intensity = 0, fog = 0, clouds = 0.2, windX = 0.5, windY = 0.05 } },
	{ "darashia", { precip = "clear", intensity = 0, fog = 0, clouds = 0.2, windX = 0.45, windY = 0.05 } },
	-- River/swamp fog without forcing rain; light clouds.
	{ "venore", { precip = "clear", intensity = 0, fog = 0.6, fogNight = 0.75, clouds = 0.35, cloudsNight = 0.4 } },
	{ "port hope", { precip = "rain", intensity = 0.55, fog = 0.2, clouds = 0.65 } },
	{ "liberty bay", { precip = "rain", intensity = 0.45, fog = 0.15, fogNight = 0.35, clouds = 0.55, windX = 0.4, windY = 0.1 } },
	{ "kazordoon", { precip = "clear", intensity = 0, fog = 0, clouds = 0 } },
}

local UNDERGROUND = { precip = "clear", intensity = 0, fog = 0, clouds = 0 }
local KEEP_SURFACE = {
	raid = true,
	arena = true,
	worldboss = true,
	soulpit = true,
	lobby = true,
}

local lastSent = {}
-- GOD override table: kind, intensity, fog, clouds, windX, windY, ...
local overrides = {}

local function isNight(period)
	if period == LIGHT_STATE_NIGHT or period == LIGHT_STATE_SUNSET then
		return true
	end
	if period == LIGHT_STATE_DAY or period == LIGHT_STATE_SUNRISE then
		return false
	end
	local level = getWorldLight()
	return (tonumber(level) or 250) < 150
end

local function profileFor(player, desc)
	if not desc then
		return { precip = "clear", intensity = 0, fog = 0, clouds = 0 }
	end
	local kind = tostring(desc.kind or "")
	local profile = BY_KIND[kind]
	local name = string.lower(tostring(desc.name or ""))
	for _, entry in ipairs(BY_NAME) do
		if name ~= "" and string.find(name, entry[1], 1, true) then
			profile = entry[2]
			break
		end
	end
	if not profile then
		profile = BY_KIND.wild
	end
	if not KEEP_SURFACE[kind] then
		local pos = player and player:getPosition()
		if pos and (tonumber(pos.z) or 7) > 7 then
			profile = UNDERGROUND
		end
	end
	return profile
end

local function layerAmount(profile, night, dayKey, nightKey)
	if night and profile[nightKey] ~= nil then
		return tonumber(profile[nightKey]) or 0
	end
	return tonumber(profile[dayKey]) or 0
end

local function payloadFor(player, desc, period)
	local ov = overrides[player:getId()]
	if ov then
		return {
			type = "climate",
			kind = ov.kind or "clear",
			intensity = tonumber(ov.intensity) or 0,
			fog = tonumber(ov.fog) or 0,
			clouds = tonumber(ov.clouds) or 0,
			windX = tonumber(ov.windX) or 0,
			windY = tonumber(ov.windY) or 0,
			precipSoundId = tonumber(ov.precipSoundId) or 0,
			transitionMs = tonumber(ov.transitionMs) or 1500,
		}
	end
	local profile = profileFor(player, desc)
	local night = isNight(period)
	local precip = night and (profile.precipNight or profile.precip) or profile.precip
	local intensity = tonumber(profile.intensity) or 0
	if night and profile.intensityNight ~= nil then
		intensity = tonumber(profile.intensityNight) or intensity
	end
	if precip == "clear" then
		intensity = 0
	end
	return {
		type = "climate",
		kind = precip or "clear",
		intensity = intensity,
		fog = layerAmount(profile, night, "fog", "fogNight"),
		clouds = layerAmount(profile, night, "clouds", "cloudsNight"),
		windX = tonumber(profile.windX) or 0,
		windY = tonumber(profile.windY) or 0,
		precipSoundId = 0,
		transitionMs = 2000,
	}
end

local function fingerprint(payload)
	return string.format("%s:%.2f:%.2f:%.2f:%.2f:%.2f:%d", payload.kind, payload.intensity or 0, payload.fog or 0,
		payload.clouds or 0, payload.windX or 0, payload.windY or 0, payload.precipSoundId or 0)
end

function PlaceClimate.selection(player, desc, period)
	return payloadFor(player, desc, period)
end

--- Merge fields into the player's override (fog/clouds/precip stack).
function PlaceClimate.setOverride(player, fields)
	if not player then
		return
	end
	local pid = player:getId()
	if not fields then
		overrides[pid] = nil
		return
	end
	if fields.clearAll then
		overrides[pid] = {
			kind = "clear",
			intensity = 0,
			fog = 0,
			clouds = 0,
			windX = 0,
			windY = 0,
			transitionMs = fields.transitionMs or 1000,
		}
		return
	end
	local ov = overrides[pid]
	if not ov then
		-- Seed from current place so /climate fog keeps existing clouds/rain.
		local desc = InstanceWorld and InstanceWorld.describeCurrent(player) or nil
		ov = payloadFor(player, desc)
		ov.type = nil
	end
	for k, v in pairs(fields) do
		if k ~= "force" and k ~= "clearAll" then
			ov[k] = v
		end
	end
	overrides[pid] = ov
end

function PlaceClimate.clearOverride(player)
	if player then
		overrides[player:getId()] = nil
	end
end

function PlaceClimate.overrideOf(player)
	return player and overrides[player:getId()] or nil
end

function PlaceClimate.send(player, desc, period)
	if not player or not IdleUtil or not IdleUtil.jsonSender then
		return false
	end
	if desc == nil and InstanceWorld then
		desc = InstanceWorld.describeCurrent(player)
	end
	local payload = payloadFor(player, desc, period)
	local pid = player:getId()
	local key = fingerprint(payload)
	local prev = lastSent[pid]
	if prev == key then
		return true
	end
	local send = IdleUtil.jsonSender(ExpeditionConfig and ExpeditionConfig.OPCODE or 113)
	if not send(player, payload) then
		return false
	end
	lastSent[pid] = key
	return true
end

function PlaceClimate.forget(player)
	if player then
		local pid = player:getId()
		lastSent[pid] = nil
		overrides[pid] = nil
	end
end

function PlaceClimate.refreshOnline(period)
	for _, player in ipairs(Game.getPlayers() or {}) do
		PlaceClimate.send(player, nil, period)
	end
end

--- Broadcast merge override to every player in `player`'s instance (GOD scrub).
function PlaceClimate.broadcastOverride(player, fields)
	if not player then
		return 0
	end
	local key = player.getInstanceId and player:getInstanceId() or nil
	local n = 0
	for _, other in ipairs(Game.getPlayers() or {}) do
		if not key or (other.getInstanceId and other:getInstanceId() == key) then
			PlaceClimate.setOverride(other, fields)
			if PlaceClimate.send(other) then
				n = n + 1
			end
		end
	end
	return n
end
