-- Area ambience (SoundTrigger type 0) and music (type 1), sent with the instance identity.
-- Ids are SoundAmbientEffect_t / SoundMusicEffect_t and match sounds.dat template ids.
-- Object ambience is chosen by the client from nearby tiles; it is not sent here.
PlaceSound = PlaceSound or {}

-- Looping music templates only (catalog music_type MUSIC, not TITLE or IMMEDIATE).
local MUSIC = {
	silence = 0,
	city = 8,
	settlement = 10,
	hub = 11,
	wild = 12,
	hunt = 13,
	connector = 14,
	lobby = 15,
	raid = 16,
	arena = 17,
	worldboss = 18,
	soulpit = 19,
	underground = 20,
	desert = 14,
	ice = 17,
	port = 15,
	swamp = 10,
	magic = 21,
	elf = 23,
	cave = 19,
}

local BY_KIND = {
	city = { day = 25, night = 28, music = MUSIC.city },
	settlement = { day = 11, night = 8, music = MUSIC.settlement },
	hub = { day = 11, night = 8, music = MUSIC.hub },
	wild = { day = 7, night = 8, music = MUSIC.wild },
	hunt = { day = 3, night = 36, music = MUSIC.hunt },
	connector = { day = 7, night = 8, music = MUSIC.connector },
	lobby = { day = 11, night = 11, music = MUSIC.lobby },
	raid = { day = 13, night = 13, music = MUSIC.raid },
	arena = { day = 13, night = 13, music = MUSIC.arena },
	worldboss = { day = 20, night = 20, music = MUSIC.worldboss },
	soulpit = { day = 17, night = 17, music = MUSIC.soulpit },
}

-- First matching substring of the instance display name wins.
local BY_NAME = {
	{ "kazordoon", { day = 15, night = 41, music = MUSIC.cave } },
	{ "venore", { day = 23, night = 28, music = MUSIC.swamp } },
	{ "thais", { day = 25, night = 28, music = MUSIC.city } },
	{ "carlin", { day = 25, night = 28, music = MUSIC.hub } },
	{ "edron", { day = 3, night = 36, music = MUSIC.wild } },
	{ "port hope", { day = 11, night = 8, music = MUSIC.hunt } },
	{ "liberty bay", { day = 14, night = 8, music = MUSIC.port } },
	{ "ankrahmun", { day = 4, night = 8, music = MUSIC.desert } },
	{ "darashia", { day = 4, night = 8, music = 24 } },
	{ "svargrond", { day = 9, night = 71, music = MUSIC.ice } },
	{ "yalahar", { day = 31, night = 8, music = MUSIC.magic } },
	{ "ab'dendriel", { day = 3, night = 36, music = MUSIC.elf } },
}

local UNDERGROUND = { day = 15, night = 41, music = MUSIC.underground }
local KEEP_SURFACE = {
	raid = true,
	arena = true,
	worldboss = true,
	soulpit = true,
	lobby = true,
}

local lastSent = {}

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
		return { day = 0, night = 0, music = MUSIC.silence }
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

--- Ambient id, music id for the player's current instance.
function PlaceSound.selection(player, desc, period)
	local profile = profileFor(player, desc)
	local ambient = isNight(period) and profile.night or profile.day
	return ambient or 0, profile.music or 0
end

--- Send whichever of the two triggers changed. Id 0 stops that channel.
function PlaceSound.send(player, desc, period)
	if not player or not player.sendAmbientSoundEffect or not player.sendMusicSoundEffect then
		return false
	end
	if desc == nil and InstanceWorld then
		desc = InstanceWorld.describeCurrent(player)
	end
	local ambient, music = PlaceSound.selection(player, desc, period)
	local pid = player:getId()
	local prev = lastSent[pid]
	if not prev or prev.ambient ~= ambient then
		player:sendAmbientSoundEffect(ambient)
	end
	if not prev or prev.music ~= music then
		player:sendMusicSoundEffect(music)
	end
	local pos = player:getPosition()
	lastSent[pid] = { ambient = ambient, music = music, z = pos and pos.z or 7 }
	return true
end

--- Stairs in the same instance cross the surface/cave bed. A walk that stays on the same side does not resend.
function PlaceSound.onStep(player)
	if not player then
		return
	end
	local pos = player:getPosition()
	local z = pos and tonumber(pos.z) or 7
	local prev = lastSent[player:getId()]
	if prev and ((prev.z or 7) > 7) == (z > 7) then
		prev.z = z
		return
	end
	PlaceSound.send(player)
end

function PlaceSound.forget(player)
	if player then
		lastSent[player:getId()] = nil
	end
end

function PlaceSound.refreshOnline(period)
	for _, player in ipairs(Game.getPlayers() or {}) do
		PlaceSound.send(player, nil, period)
	end
end
