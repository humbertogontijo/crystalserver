-- Discovery System ("Measuring Tibia") - AUTOMATIC exploration (no "Start Discovering" button).
-- Entering a registered subarea auto-activates discovery: the server picks viewpoints from the
-- tibiamaps flag catalog for that subarea (lib/idleot/discovery/pois.generated.lua), keeping only
-- points inside the subarea's floors and inside some walkable instance fence; walking within 4 sqm
-- of one marks it found; finishing the set unlocks the subarea permanently (KV).
-- Wire: S2C 0xDD sub 1 (DiscoveryData), sub 5 (SetDiscoveryArea — viewport-visible unfound only),
-- sub 10/11 (current/exploring). Clients must not foreshadow distant POIs on the cyclopedia map.
-- Rewards: achievements 470 "Widely Travelled" / 539 "Measuring the World", Discoverer outfit
-- (1094/1095) + addons, cyclopedia MAP titles 74/75 via kv "discovery/map-percent" + checkMap().

-- exact client footprints (generated from subarea-*.bmp.lzma masks); load-order guard
if not DiscoveryGeometry then
	dofile(DATA_DIRECTORY .. "/lib/idleot/discovery/geometry.lua")
end
if not DiscoverySubareas then
	dofile(DATA_DIRECTORY .. "/lib/idleot/discovery/subareas.lua")
end
if not DiscoveryPois then
	dofile(DATA_DIRECTORY .. "/lib/idleot/discovery/pois.generated.lua")
end

DiscoverySystem = DiscoverySystem or {}

-- Match Crystal MAP_MAX_CLIENT_VIEW_PORT_* (visible-sqm 12 @ 21:9 → aware radius 15).
-- Classic 7×5 left POIs off-screen on widescreen Idle FOV.
local VIEW_X = (ExpeditionConfig and tonumber(ExpeditionConfig.MAP_MAX_CLIENT_VIEW_PORT_X)) or 15
local VIEW_Y = (ExpeditionConfig and tonumber(ExpeditionConfig.MAP_MAX_CLIENT_VIEW_PORT_Y)) or 15
if VIEW_X < 15 then
	VIEW_X = 15
end
if VIEW_Y < 15 then
	VIEW_Y = 15
end
local DISCOVER_RADIUS = 4 -- Chebyshev: viewpoint counts as found only within this range
local POI_TARGET = 7
-- bump only when subarea ids/footprints change incompatibly: rolled viewpoints are wiped on
-- login (completed subareas are kept). Catalog changes need no bump - saved sets are
-- reconciled against the usable catalog when the player enters the subarea.
local GEOMETRY_VERSION = 6

local OUTFIT_DISCOVERER_FEMALE = 1095
local OUTFIT_DISCOVERER_MALE = 1094
local ACHIEVEMENT_WIDELY_TRAVELLED = 470
local ACHIEVEMENT_MEASURING_THE_WORLD = 539

-- main areas: taken 1:1 from the client (DiscoveryGeometry.mains, real area_id -> name)
local MAIN_AREAS = DiscoveryGeometry.mains

-- Measuring Tibia discoverable subareas only (https://tibia.fandom.com/wiki/Measuring_Tibia_Quest).
-- Geometry may include corridors / dungeons / stubs (e.g. Trail to Rascacoon) that are
-- not part of the quest — those stay in SUBAREA_LIST for footprint / donate boosts but
-- never start exploration or count toward progress. A listed subarea with no usable
-- viewpoint (see usablePois) is treated the same way.
local DISCOVERABLE = {
	[28] = true, -- Thais City
	[29] = true, -- Thais Surroundings
	[33] = true, -- Thais Trolls' Cave
	[34] = true, -- Mount Sternum
	[35] = true, -- Fibula
	[38] = true, -- Ghostlands
	[39] = true, -- Folda
	[40] = true, -- Fields of Glory
	[43] = true, -- Carlin Surroundings
	[45] = true, -- Kazordoon Troll Den
	[46] = true, -- Orc Lands
	[47] = true, -- Femor Hills
	[49] = true, -- Horned Fox Lair
	[50] = true, -- Kazordoon Surroundings
	[53] = true, -- Draconia
	[54] = true, -- Elvenbane
	[55] = true, -- Ab'Dendriel Surroundings
	[57] = true, -- Edron Troll Den
	[58] = true, -- Edron Goblin Den
	[59] = true, -- Edron Orc Lands
	[60] = true, -- Edron Dragon Lair
	[61] = true, -- Cyclopolis
	[63] = true, -- Edron Surroundings
	[64] = true, -- Daramian Minotaur Pyramid
	[66] = true, -- Drefia
	[68] = true, -- Northern Darama Desert
	[69] = true, -- Amazon Camp
	[70] = true, -- Black Knight Villa
	[71] = true, -- Venore Dragon Lair
	[72] = true, -- Green Claw Swamp
	[73] = true, -- Outlaw Camp
	[74] = true, -- Dark Cathedral
	[75] = true, -- Plains of Havoc
	[76] = true, -- Shadowthorn
	[77] = true, -- Venore Southern Swamp
	[78] = true, -- Venore Surroundings
	[81] = true, -- Ankrahmun Pharaoh Tombs
	[84] = true, -- Kha'zeel Dragon Lairs
	[85] = true, -- Southern Darama Desert
	[86] = true, -- Banuta
	[87] = true, -- Chor
	[90] = true, -- Forbidden Lands of Tiquanda
	[92] = true, -- Port Hope Surroundings
	[94] = true, -- Vandura Cultist Hideout
	[95] = true, -- Liberty Bay Surroundings
	[96] = true, -- Meriana
	[97] = true, -- Nargor
	[98] = true, -- Talahu
	[99] = true, -- Hellgorge
	[100] = true, -- Laguna Islands
	[101] = true, -- Treasure Island
	[102] = true, -- Calassa
	[104] = true, -- Jakundaf Desert
	[106] = true, -- Ulderek's Rock
	[107] = true, -- Kha'zeel Mountains
	[109] = true, -- Nibelor
	[110] = true, -- Okolnir
	[111] = true, -- Helheim
	[112] = true, -- Grimlund
	[113] = true, -- Tyrsung
	[114] = true, -- Formorgar Glacier
	[116] = true, -- Krimhorn
	[117] = true, -- Svargrond Surroundings
	[125] = true, -- Vengoth
	[127] = true, -- Yalahar Trade Quarter
	[128] = true, -- Yalahar Sunken Quarter
	[129] = true, -- Yalahar Factory Quarter
	[130] = true, -- Yalahar Magician Quarter
	[131] = true, -- Yalahar Cemetery Quarter
	[132] = true, -- Yalahar Alchemist Quarter
	[133] = true, -- Yalahar Arena Quarter
	[134] = true, -- Yalahar Foreigner Quarter
	[135] = true, -- Mistrock
	[136] = true, -- Fenrock
	[138] = true, -- Isle of Evil
	[141] = true, -- Zao Orc Fortress
	[142] = true, -- Zao Steppe
	[143] = true, -- Zzaion
	[144] = true, -- Dragonblaze Peaks
	[145] = true, -- Muggy Plains
	[148] = true, -- Razachai
	[149] = true, -- Corrupted Gardens
	[150] = true, -- Emperor's Castle
	[151] = true, -- Chazorai
	[152] = true, -- Spirittrails
	[167] = true, -- Hive Pools
	[168] = true, -- Hive Pyramids
	[184] = true, -- Southern Terramite Tunnels
	[192] = true, -- Rorc Plains
	[195] = true, -- Upper Roshamuul
	[198] = true, -- Lower Roshamuul
	[200] = true, -- Roshamuul Mountains
	[208] = true, -- Rathleton Slum
	[209] = true, -- Oramond Mountain Hideout
	[210] = true, -- Oramond Minotaur Camp
	[213] = true, -- Oramond Marshes
	[214] = true, -- Rathleton Workshops
	[217] = true, -- Lion's Rock
	[228] = true, -- Vandura Quara Caves
	[235] = true, -- Asura Palace
	[238] = true, -- Medusa Tower
	[239] = true, -- Gloom Caverns
	[242] = true, -- Edron Hero Fortress
	[243] = true, -- Grimvale
	[254] = true, -- Krailos Steppe
	[256] = true, -- Krailos Ruins
	[274] = true, -- Stonehome
	[279] = true, -- Ice Islands
	[280] = true, -- Vega
	[281] = true, -- Senja
	[282] = true, -- Goroma
	[283] = true, -- Ramoa
	[284] = true, -- Malada
	[285] = true, -- Kharos
	[286] = true, -- Cormaya
	[287] = true, -- Inukaya
	[288] = true, -- Isle of the Kings
	[289] = true, -- Bittermor
	[290] = true, -- Ragnir
	[295] = true, -- Greenshore
	[296] = true, -- Darashia City
	[297] = true, -- Ankrahmun City
	[298] = true, -- Svargrond City
	[301] = true, -- Rathleton City
	[302] = true, -- Gray Beach
	[303] = true, -- Ogre Village
	[308] = true, -- Fae Village
	[309] = true, -- Port Hope City
	[312] = true, -- Liberty Bay City
	[313] = true, -- Krailos Mines
	[314] = true, -- Feyrist Meadows
	[319] = true, -- Falcon Bastion
	[354] = true, -- Cobra Bastion
	[356] = true, -- Nykri Delta
	[357] = true, -- Issavi
	[360] = true, -- Kilmaresh Central Steppe
	[361] = true, -- Kilmaresh Southern Steppe
	[362] = true, -- Green Belt
	[365] = true, -- Kilmaresh Mountains
	[391] = true, -- Bounac
	[394] = true, -- Rascacoon
	[397] = true, -- The Wreckoning
	[437] = true, -- Murmuring Wilderness
	[438] = true, -- Silent Waters
	[439] = true, -- Fading Isles
	[440] = true, -- Emerald Gardens
	[441] = true, -- Sparkling Lagoon
	[442] = true, -- Stardance Mountains
	[443] = true, -- Moonfall
	[444] = true, -- Silvertides
	[445] = true, -- Ingol
	[272] = true, -- Kazordoon City
	[273] = true, -- Ab'Dendriel City
	[275] = true, -- Edron Castle
	[271] = true, -- Carlin City
	[276] = true, -- Venore City
	[461] = true, -- Yalahar Centre
	[475] = true, -- Oskayaat
	[498] = true, -- Candia
	[504] = true, -- Azzilon Castle
	[516] = true, -- Isle of Ada - Adaean Mines
	[518] = true, -- Isle of Ada - Outskirts
	[519] = true, -- Isle of Ada - Bastion
	[526] = true, -- Targuna
	[528] = true, -- Aragonia
}

-- footprints + floor rules live in lib/idleot/discovery/subareas.lua (shared with gen_pois.py)
local SUBAREA_LIST = DiscoverySubareas.list

DiscoverySubareas.regionCipAt = function(position)
	local region = Game.getSubareaAt(Position(position.x, position.y, position.z))
	local cipId = region and tonumber(region.cipId) or 0
	return cipId > 0 and cipId or nil
end
for _, def in ipairs(SUBAREA_LIST) do
	def.discoverable = DISCOVERABLE[def.id] == true
end

-- Viewpoints a player can actually stand on: inside the subarea's own session footprint
-- (right floor) and inside some walkable instance fence. Fences are static after startup,
-- so the result is cached per subarea.
local usableBySub = {}
local usableReported = false

local function usablePois(def)
	local cached = usableBySub[def.id]
	if cached then
		return cached
	end
	local reachable = InstanceWorld and InstanceWorld.isReachable
	local list = {}
	for _, p in ipairs((DiscoveryPois and DiscoveryPois[def.id]) or {}) do
		local pos = { x = p.x, y = p.y, z = p.z }
		if DiscoverySubareas.inSubarea(pos, def) and (not reachable or reachable(pos)) then
			list[#list + 1] = p
		end
	end
	usableBySub[def.id] = list
	return list
end

local function isDiscoverable(def)
	return def.discoverable and #usablePois(def) > 0
end

local function reportUnusableSubareas()
	if usableReported then
		return
	end
	usableReported = true
	local names = {}
	for _, def in ipairs(SUBAREA_LIST) do
		if def.discoverable and #usablePois(def) == 0 then
			names[#names + 1] = string.format("%s (%d)", def.name, def.id)
		end
	end
	if #names > 0 then
		logger.warn("[DiscoverySystem] {} quest subareas have no reachable viewpoint and are not discoverable: {}", #names, table.concat(names, ", "))
	end
end

local sessions = {} -- guid -> { subId, def, pois = { {x, y, z, found} }, foundCount, completed }

-- ===== Area donations -> "Improved Respawn Rate" (0xDD sub 9) =====
-- Players donate gold to a MAIN area. When the pool reaches the goal, the boost is
-- SCHEDULED: it activates at the NEXT server save and lasts until the following one
-- (24h), then the cycle can repeat (goal amount is consumed, excess carries over).
-- While active, every spawn inside the area's footprints respawns twice as fast.
local DONATION_GOAL = 10000000 -- 10kk per main area
local BOOST_DURATION = 24 * 60 * 60 -- seconds; one full server-save cycle
local donationStore = kv.scoped("discovery-donations")
-- publish the goal for the C++ donation handler (map-UI "Donate", protocolgame 0x92)
donationStore:set("goal", DONATION_GOAL)

local function donationsOf(areaId)
	return donationStore:get("area-" .. areaId) or 0
end

local function boostUntil(areaId)
	return donationStore:get("boost-until-" .. areaId) or 0
end

local function isRespawnBoosted(areaId)
	return os.time() < boostUntil(areaId)
end

local function isBoostScheduled(areaId)
	return donationsOf(areaId) >= DONATION_GOAL
end

function DiscoverySystem.sendDonations(player)
	local entries = {}
	local mainIds = {}
	for mainId in pairs(MAIN_AREAS) do
		mainIds[#mainIds + 1] = mainId
	end
	table.sort(mainIds)
	for _, mainId in ipairs(mainIds) do
		entries[#entries + 1] = { mainId, isRespawnBoosted(mainId), donationsOf(mainId) }
	end
	player:sendDiscoveryDonations(DONATION_GOAL, entries)
end

function DiscoverySystem.applyImprovedRespawnZones()
	local rects = {}
	local boosted = {}
	for _, def in ipairs(SUBAREA_LIST) do
		if isRespawnBoosted(def.mainArea) then
			boosted[def.mainArea] = true
			local r = def.rects
			for i = 1, #r, 4 do
				rects[#rects + 1] = { r[i], r[i + 1], r[i + 2], r[i + 3] }
			end
			for _, e in ipairs(def.extra) do
				rects[#rects + 1] = { e.x1, e.y1, e.x2, e.y2 }
			end
		end
	end
	Game.setImprovedRespawnZones(rects)
	local names = {}
	for mainId in pairs(boosted) do
		names[#names + 1] = MAIN_AREAS[mainId] or tostring(mainId)
	end
	return #rects, names
end

function DiscoverySystem.donate(player, areaId, amount)
	if not MAIN_AREAS[areaId] then
		return false, string.format("unknown main area id %d", areaId)
	end
	if not amount or amount <= 0 then
		return false, "amount must be positive"
	end
	local wasScheduled = isBoostScheduled(areaId)
	donationStore:set("area-" .. areaId, donationsOf(areaId) + amount)
	local nowScheduled = isBoostScheduled(areaId) and not wasScheduled
	for _, p in ipairs(Game.getPlayers()) do
		DiscoverySystem.sendDonations(p)
		if nowScheduled then
			p:sendTextMessage(MESSAGE_EVENT_ADVANCE, string.format("Donations for %s reached their goal - improved respawn rate will activate at the next server save and last one day!", MAIN_AREAS[areaId]))
		end
	end
	return true
end

-- Server-save boundary: consume filled pools -> activate their boost for one day;
-- boosts from the previous day expire here naturally (time comparison).
-- Called from global_server_save.lua and from the /disco ss test command.
function DiscoverySystem.onServerSave()
	local activated = {}
	for mainId in pairs(MAIN_AREAS) do
		if isBoostScheduled(mainId) then
			donationStore:set("area-" .. mainId, donationsOf(mainId) - DONATION_GOAL)
			donationStore:set("boost-until-" .. mainId, os.time() + BOOST_DURATION)
			activated[#activated + 1] = MAIN_AREAS[mainId] or tostring(mainId)
		end
	end
	DiscoverySystem.applyImprovedRespawnZones()
	for _, p in ipairs(Game.getPlayers()) do
		DiscoverySystem.sendDonations(p)
		if #activated > 0 then
			p:sendTextMessage(MESSAGE_EVENT_ADVANCE, string.format("Improved respawn rate is now active in: %s (for one day).", table.concat(activated, ", ")))
		end
	end
	return #activated
end

-- test/admin helper: zero every pool and boost, deactivate zones, refresh everyone
function DiscoverySystem.resetDonations()
	for mainId in pairs(MAIN_AREAS) do
		donationStore:set("area-" .. mainId, 0)
		donationStore:set("boost-until-" .. mainId, 0)
	end
	DiscoverySystem.applyImprovedRespawnZones()
	for _, p in ipairs(Game.getPlayers()) do
		DiscoverySystem.sendDonations(p)
	end
end

function DiscoverySystem.donationStatus()
	local lines = {}
	local mainIds = {}
	for mainId in pairs(MAIN_AREAS) do
		mainIds[#mainIds + 1] = mainId
	end
	table.sort(mainIds)
	for _, mainId in ipairs(mainIds) do
		local donated = donationsOf(mainId)
		local until_ = boostUntil(mainId)
		if donated > 0 or os.time() < until_ then
			local state = ""
			if os.time() < until_ then
				state = string.format(" [ACTIVE until %s]", os.date("%d.%m %H:%M", until_))
			elseif donated >= DONATION_GOAL then
				state = " [SCHEDULED - activates at next server save]"
			end
			lines[#lines + 1] = string.format("%s: %d/%d%s", MAIN_AREAS[mainId], donated, DONATION_GOAL, state)
		end
	end
	if #lines == 0 then
		lines[1] = "no donations yet"
	end
	return lines
end

-- safety net for boundaries not covered by an SS event (e.g. expiry while the server
-- runs past 24h): re-apply zones whenever the set of active boosts changes
local lastBoostSignature = nil

local discoveryBoostWatch = GlobalEvent("DiscoveryBoostWatch")

function discoveryBoostWatch.onThink(interval)
	local sig = {}
	for mainId in pairs(MAIN_AREAS) do
		if isRespawnBoosted(mainId) then
			sig[#sig + 1] = mainId
		end
	end
	table.sort(sig)
	local s = table.concat(sig, ",")
	if s ~= lastBoostSignature then
		lastBoostSignature = s
		DiscoverySystem.applyImprovedRespawnZones()
		for _, p in ipairs(Game.getPlayers()) do
			DiscoverySystem.sendDonations(p)
		end
	end
	return true
end

discoveryBoostWatch:interval(60000)
discoveryBoostWatch:register()

local function kv(player)
	return player:kv():scoped("discovery")
end

local function isCompleted(player, subId)
	return kv(player):get("done-" .. subId) == true
end

local function serializePois(pois)
	local parts = {}
	for _, p in ipairs(pois) do
		parts[#parts + 1] = string.format("%d,%d,%d,%d", p.x, p.y, p.z, p.found and 1 or 0)
	end
	return table.concat(parts, "|")
end

local function deserializePois(str)
	if not str or str == "" then
		return nil
	end
	local pois = {}
	for chunk in str:gmatch("[^|]+") do
		local x, y, z, f = chunk:match("(%d+),(%d+),(%d+),(%d+)")
		if not x then
			return nil
		end
		pois[#pois + 1] = { x = tonumber(x), y = tonumber(y), z = tonumber(z), found = f == "1" }
	end
	return #pois > 0 and pois or nil
end

local function countFound(pois)
	local n = 0
	for _, p in ipairs(pois) do
		if p.found then
			n = n + 1
		end
	end
	return n
end

local function poisToWireVisible(pois, playerPos)
	-- Only unfound viewpoints currently inside the game viewport. Discovered points are never
	-- re-sent (no map foreshadowing / no post-discovery markers). Distant unfound points stay
	-- server-side until the player walks near them.
	local points = {}
	if not pois or not playerPos then
		return points
	end
	for _, p in ipairs(pois) do
		if not p.found and p.z == playerPos.z and math.abs(p.x - playerPos.x) <= VIEW_X and math.abs(p.y - playerPos.y) <= VIEW_Y then
			points[#points + 1] = { p.x, p.y, p.z, 0 }
		end
	end
	return points
end

local function poiKey(x, y, z)
	return string.format("%d,%d,%d", x, y, z)
end

-- Idle POI markers must be player-scoped. Tile-wide addMagicEffect resolves empty POI
-- tiles to instance 0, so city/settlement/hunt players never see them.
local function clearIdlePoiEffects(player, session)
	if not session or not session.idleEffects then
		return
	end
	for key, pos in pairs(session.idleEffects) do
		Position(pos.x, pos.y, pos.z):removeMagicEffect(CONST_ME_PINK_VORTEX, player)
		session.idleEffects[key] = nil
	end
end

local function syncIdlePoiEffects(player, session)
	if not player or not session or not session.pois then
		return
	end
	session.idleEffects = session.idleEffects or {}
	local playerPos = player:getPosition()
	local want = {}
	for _, p in ipairs(session.pois) do
		if not p.found and p.z == playerPos.z and math.abs(p.x - playerPos.x) <= VIEW_X and math.abs(p.y - playerPos.y) <= VIEW_Y then
			local key = poiKey(p.x, p.y, p.z)
			want[key] = { x = p.x, y = p.y, z = p.z }
		end
	end
	for key, pos in pairs(session.idleEffects) do
		if not want[key] then
			Position(pos.x, pos.y, pos.z):removeMagicEffect(CONST_ME_PINK_VORTEX, player)
			session.idleEffects[key] = nil
		end
	end
	-- Send once per visible POI. Do not pulse/re-add — CIP effect 193 loops, and
	-- remove+resend left stacked/orphan markers on the client.
	for key, pos in pairs(want) do
		if not session.idleEffects[key] then
			Position(pos.x, pos.y, pos.z):sendMagicEffect(CONST_ME_PINK_VORTEX, player)
			session.idleEffects[key] = pos
		end
	end
end

local function wireSignature(points)
	local parts = {}
	for _, p in ipairs(points) do
		parts[#parts + 1] = string.format("%d,%d,%d", p[1], p[2], p[3])
	end
	table.sort(parts)
	return table.concat(parts, "|")
end

function DiscoverySystem.findSubarea(position)
	return DiscoverySubareas.find(position)
end

local function poiTargetFor(def)
	return math.min(POI_TARGET, #usablePois(def))
end

-- All usable viewpoints of this subarea in pick order: a deterministic shuffle per
-- (player, subarea), with points already in view pushed to the back. Never invents
-- random map coordinates.
local function orderedPool(player, def)
	local catalog = usablePois(def)
	local pool = {}
	for i, p in ipairs(catalog) do
		pool[i] = { x = p.x, y = p.y, z = p.z, found = false }
	end
	local seed = (player:getGuid() % 1000003) * 10007 + def.id
	local function rand()
		seed = (seed * 1103515245 + 12345) % 2147483648
		return seed
	end
	for i = #pool, 2, -1 do
		local j = (rand() % i) + 1
		pool[i], pool[j] = pool[j], pool[i]
	end

	local playerPos = player:getPosition()
	local preferred, fallback = {}, {}
	for _, p in ipairs(pool) do
		local inView = p.z == playerPos.z and math.abs(p.x - playerPos.x) <= VIEW_X + 1 and math.abs(p.y - playerPos.y) <= VIEW_Y + 1
		if inView then
			fallback[#fallback + 1] = p
		else
			preferred[#preferred + 1] = p
		end
	end
	local ordered = preferred
	for _, p in ipairs(fallback) do
		ordered[#ordered + 1] = p
	end
	return ordered
end

local function selectPois(player, def)
	local ordered = orderedPool(player, def)
	local pois = {}
	for i = 1, poiTargetFor(def) do
		pois[i] = ordered[i]
	end
	return #pois > 0 and pois or nil
end

-- Saved sets may predate a catalog / fence change: keep still-usable points (with their
-- found state) and top up from the pick order so progress is never lost or stuck.
local function reconcilePois(player, def, stored)
	local usableKeys = {}
	for _, p in ipairs(usablePois(def)) do
		usableKeys[poiKey(p.x, p.y, p.z)] = true
	end
	local pois, have = {}, {}
	for _, p in ipairs(stored) do
		local key = poiKey(p.x, p.y, p.z)
		if usableKeys[key] and not have[key] then
			pois[#pois + 1] = p
			have[key] = true
		end
	end
	local target = poiTargetFor(def)
	if #pois < target then
		for _, p in ipairs(orderedPool(player, def)) do
			if #pois >= target then
				break
			end
			local key = poiKey(p.x, p.y, p.z)
			if not have[key] then
				pois[#pois + 1] = p
				have[key] = true
			end
		end
	end
	local changed = #pois ~= #stored
	if not changed then
		for i, p in ipairs(pois) do
			if p ~= stored[i] then
				changed = true
				break
			end
		end
	end
	return pois, changed
end

local function subareaCounts(player, mainId)
	local total, done = 0, 0
	for _, def in ipairs(SUBAREA_LIST) do
		if def.mainArea == mainId and isDiscoverable(def) then
			total = total + 1
			if isCompleted(player, def.id) then
				done = done + 1
			end
		end
	end
	return total, done
end

function DiscoverySystem.sendDiscoveryData(player)
	local totals, dones = {}, {}
	local discovered = {}
	local discoverable = {}
	for _, def in ipairs(SUBAREA_LIST) do
		local mainId = def.mainArea
		if MAIN_AREAS[mainId] and isDiscoverable(def) then
			totals[mainId] = (totals[mainId] or 0) + 1
			if isCompleted(player, def.id) then
				dones[mainId] = (dones[mainId] or 0) + 1
				discovered[#discovered + 1] = def.id
			else
				discoverable[#discoverable + 1] = def.id
			end
		end
	end
	local mains = {}
	for mainId, total in pairs(totals) do
		local done = dones[mainId] or 0
		local progress = math.floor(done / total * 100)
		local status = done == total and 3 or 1
		mains[#mains + 1] = { mainId, status, progress }
	end
	player:sendDiscoveryData(mains, discovered, discoverable)
end

function DiscoverySystem.grantMilestones(player)
	local totalMains, doneMains = 0, 0
	for mainId, _ in pairs(MAIN_AREAS) do
		local total, done = subareaCounts(player, mainId)
		if total > 0 then
			totalMains = totalMains + 1
			if done == total then
				doneMains = doneMains + 1
			end
		end
	end
	local percent = totalMains > 0 and math.floor(doneMains / totalMains * 100) or 0
	kv(player):set("map-percent", percent)

	if doneMains >= 1 then
		-- first fully explored main area: Discoverer outfit + "Widely Travelled"
		if not player:hasAchievement(ACHIEVEMENT_WIDELY_TRAVELLED) then
			player:addAchievement(ACHIEVEMENT_WIDELY_TRAVELLED)
			player:sendTextMessage(MESSAGE_EVENT_ADVANCE, "You have earned the Discoverer outfit!")
		end
		player:addOutfit(OUTFIT_DISCOVERER_MALE)
		player:addOutfit(OUTFIT_DISCOVERER_FEMALE)
	end
	if percent >= 50 then
		player:addOutfitAddon(OUTFIT_DISCOVERER_MALE, 1)
		player:addOutfitAddon(OUTFIT_DISCOVERER_FEMALE, 1)
	end
	if percent >= 100 then
		if not player:hasAchievement(ACHIEVEMENT_MEASURING_THE_WORLD) then
			player:addAchievement(ACHIEVEMENT_MEASURING_THE_WORLD)
		end
		player:addOutfitAddon(OUTFIT_DISCOVERER_MALE, 2)
		player:addOutfitAddon(OUTFIT_DISCOVERER_FEMALE, 2)
	end

	-- cyclopedia MAP titles (74 Dedicated Entrepreneur @50%, 75 Globetrotter @100%) read map-percent
	player:checkNewTitles()
end

local function sendAreaState(player, subId, session, active, force)
	local wire = {}
	if active and session and session.pois then
		wire = poisToWireVisible(session.pois, player:getPosition())
		syncIdlePoiEffects(player, session)
	elseif session then
		clearIdlePoiEffects(player, session)
	end
	local key = wireSignature(wire)
	if not force and session and session.lastWireKey == key and session.lastWireActive == active then
		return
	end
	if session then
		session.lastWireKey = key
		session.lastWireActive = active
	end
	local target = (session and session.poiTarget) or POI_TARGET
	player:sendDiscoveryArea(subId, active, target, wire)
end

local function completeSubarea(player, session)
	kv(player):set("done-" .. session.subId, true)
	kv(player):set("pois-" .. session.subId, "")
	session.completed = true
	player:sendDiscoveryExploring(0)
	player:getPosition():sendMagicEffect(CONST_ME_FIREWORK_BLUE)
	player:sendTextMessage(MESSAGE_EVENT_ADVANCE, string.format("Congratulations! You have fully explored %s.", session.def.name))
	sendAreaState(player, session.subId, session, false, true)
	DiscoverySystem.sendDiscoveryData(player)
	DiscoverySystem.grantMilestones(player)
end

local function enterSubarea(player, subId, def)
	if not isDiscoverable(def) then
		return
	end
	if isCompleted(player, subId) then
		player:sendDiscoveryCurrentArea(subId)
		player:sendDiscoveryExploring(0)
		player:sendTextMessage(MESSAGE_STATUS, string.format("You have entered the subarea %s.", def.name))
		sessions[player:getGuid()] = { subId = subId, def = def, completed = true }
		return
	end

	local pois = deserializePois(kv(player):get("pois-" .. subId))
	local changed = false
	if pois then
		pois, changed = reconcilePois(player, def, pois)
	else
		pois = selectPois(player, def)
		changed = true
	end
	if not pois or #pois == 0 then
		return
	end
	if changed then
		kv(player):set("pois-" .. subId, serializePois(pois))
	end

	local session = {
		subId = subId,
		def = def,
		pois = pois,
		poiTarget = #pois,
		foundCount = countFound(pois),
	}
	sessions[player:getGuid()] = session
	player:sendDiscoveryCurrentArea(subId)
	if session.foundCount >= session.poiTarget then
		-- reconcile dropped the last unfound points (no usable replacements left)
		completeSubarea(player, session)
		return
	end
	player:sendDiscoveryExploring(subId)
	sendAreaState(player, subId, session, true, true)
	local remaining = session.poiTarget - session.foundCount
	player:sendTextMessage(MESSAGE_STATUS, string.format("You have entered the subarea %s. Find %d point%s of interest to fully discover it.", def.name, remaining, remaining == 1 and "" or "s"))
end

local function leaveSubarea(player, session)
	clearIdlePoiEffects(player, session)
	sessions[player:getGuid()] = nil
	player:sendDiscoveryCurrentArea(0)
	player:sendDiscoveryExploring(0)
	if session.def then
		local suffix = session.completed and "" or " Return to discover its remaining secrets!"
		player:sendTextMessage(MESSAGE_STATUS, string.format("You have left the subarea %s.%s", session.def.name, suffix))
	end
end

-- Debug/restore: mark a subarea (or all) fully explored without walking.
function DiscoverySystem.markComplete(player, subId)
	local ids = {}
	if subId then
		ids = { subId }
	else
		for _, def in ipairs(SUBAREA_LIST) do
			if isDiscoverable(def) then
				ids[#ids + 1] = def.id
			end
		end
	end
	for _, id in ipairs(ids) do
		kv(player):set("done-" .. id, true)
		kv(player):set("pois-" .. id, "")
	end
	sessions[player:getGuid()] = nil
	player:sendDiscoveryCurrentArea(0)
	player:sendDiscoveryExploring(0)
	DiscoverySystem.sendDiscoveryData(player)
	DiscoverySystem.grantMilestones(player)
	return #ids
end

local function discoveryWalkDest(playerPos, poi)
	if not playerPos or not poi then
		return nil
	end
	local dist = math.max(math.abs(playerPos.x - poi.x), math.abs(playerPos.y - poi.y))
	if dist <= DISCOVER_RADIUS then
		return nil
	end
	local dx = playerPos.x - poi.x
	local dy = playerPos.y - poi.y
	local scale = DISCOVER_RADIUS / dist
	local idealX = poi.x + math.floor(dx * scale + (dx >= 0 and 0.5 or -0.5))
	local idealY = poi.y + math.floor(dy * scale + (dy >= 0 and 0.5 or -0.5))
	if math.max(math.abs(idealX - poi.x), math.abs(idealY - poi.y)) > DISCOVER_RADIUS then
		local sx = dx == 0 and 0 or (dx > 0 and 1 or -1)
		local sy = dy == 0 and 0 or (dy > 0 and 1 or -1)
		idealX = poi.x + sx * DISCOVER_RADIUS
		idealY = poi.y + sy * DISCOVER_RADIUS
	end
	if idealX == poi.x and idealY == poi.y then
		return nil
	end
	return Position(idealX, idealY, poi.z)
end

--- Client FAB: exclusive walk into discovery radius of a viewport-visible unfound POI.
--- Validated against the live session — does not unlock general client autoWalk.
--- Paths to any tile within DISCOVER_RADIUS (cities often block a single ideal sqm).
function DiscoverySystem.walkTowardViewpoint(player, x, y, z)
	if not player then
		return false
	end
	x, y, z = tonumber(x), tonumber(y), tonumber(z)
	if not x or not y or not z then
		return false
	end
	local session = sessions[player:getGuid()]
	if not session or session.completed or type(session.pois) ~= "table" then
		return false
	end
	local poi = nil
	for _, p in ipairs(session.pois) do
		if not p.found and tonumber(p.x) == x and tonumber(p.y) == y and tonumber(p.z) == z then
			poi = p
			break
		end
	end
	if not poi then
		return false
	end
	local pos = player:getPosition()
	if not pos or pos.z ~= z then
		return false
	end
	-- Only allow points the client could already see (same viewport filter as the wire).
	if math.abs(pos.x - x) > VIEW_X or math.abs(pos.y - y) > VIEW_Y then
		return false
	end
	if math.max(math.abs(pos.x - x), math.abs(pos.y - y)) <= DISCOVER_RADIUS then
		-- Already in range; discovery tick will mark found.
		return true
	end
	local focus = Position(x, y, z)
	if CombatAutomationMovement and CombatAutomationMovement.beginExclusiveWalk then
		-- Prefer pathfinding into the discovery ring (any walkable tile in range).
		if CombatAutomationMovement.beginExclusiveWalk(player, focus, nil, 1, DISCOVER_RADIUS) then
			return true
		end
		-- Fallback: single ideal edge tile (legacy).
		local dest = discoveryWalkDest(pos, poi)
		if dest and CombatAutomationMovement.beginExclusiveWalk(player, dest) then
			return true
		end
		return false
	end
	-- Fallback when automation movement is unavailable: exclusive autoWalk only.
	local path = player.getPathTo and player:getPathTo(focus, 1, DISCOVER_RADIUS, true, true, 128) or nil
	if type(path) ~= "table" or #path == 0 then
		local dest = discoveryWalkDest(pos, poi)
		if not dest then
			return false
		end
		path = player:getPathTo(dest, 0, 0, true, true, 128)
	end
	if type(path) ~= "table" or #path == 0 then
		return false
	end
	local dirs = {}
	for i = #path, 1, -1 do
		dirs[#dirs + 1] = path[i]
	end
	return player:autoWalk(dirs, 0, true) == true
end

local function checkViewpoints(player, session)
	local pos = player:getPosition()
	local foundNow = false
	local target = session.poiTarget or #session.pois
	for _, p in ipairs(session.pois) do
		if not p.found and p.z == pos.z and math.max(math.abs(p.x - pos.x), math.abs(p.y - pos.y)) <= DISCOVER_RADIUS then
			p.found = true
			session.foundCount = session.foundCount + 1
			foundNow = true
			local key = poiKey(p.x, p.y, p.z)
			if session.idleEffects and session.idleEffects[key] then
				Position(p.x, p.y, p.z):removeMagicEffect(CONST_ME_PINK_VORTEX, player)
				session.idleEffects[key] = nil
			end
			-- Player-scoped: empty POI tiles would otherwise resolve to instance 0.
			Position(p.x, p.y, p.z):sendMagicEffect(CONST_ME_PINK_BEAM, player) -- CIP POI Found (195)
			player:sendTextMessage(MESSAGE_EVENT_ADVANCE, string.format("You have discovered a viewpoint! (%d/%d)", session.foundCount, target))
			-- 15.30 Point of Interest banner (CLIENT_EVENT_TYPE_SUBAREA)
			if player.sendSubareaBanner then
				player:sendSubareaBanner(session.subId)
			end
			-- Echo Warden: discovered viewpoints may nudge a nearby subarea echo arm
			if EchoWarden and EchoWarden.onViewpointDiscovered then
				EchoWarden.onViewpointDiscovered(player)
			end
		end
	end
	if foundNow then
		kv(player):set("pois-" .. session.subId, serializePois(session.pois))
		if session.foundCount >= target then
			completeSubarea(player, session)
		else
			sendAreaState(player, session.subId, session, true, true)
		end
	end
end

-- isHeadless() is only set after placement, so onLogin relies on the protocol version.
local function hasClient(player)
	return not player:isHeadless() and player:getClient().version > 0
end

function DiscoverySystem.tick(player)
	local guid = player:getGuid()
	if not hasClient(player) then
		-- Progress is persisted per find; a reattached client must get fresh markers.
		sessions[guid] = nil
		return
	end
	local session = sessions[guid]
	local subId, def = DiscoverySystem.findSubarea(player:getPosition())

	if session and session.subId ~= subId then
		leaveSubarea(player, session)
		session = nil
	end
	if not session and subId then
		enterSubarea(player, subId, def)
		session = sessions[guid]
	end
	if session and not session.completed then
		-- Show idle markers first, then discover — so the player can see the POI before it pops.
		sendAreaState(player, session.subId, session, true, false)
		if sessions[guid] and not sessions[guid].completed then
			checkViewpoints(player, sessions[guid])
		end
	end
end

function DiscoverySystem.reset(player)
	local session = sessions[player:getGuid()]
	if session then
		clearIdlePoiEffects(player, session)
	end
	for _, def in ipairs(SUBAREA_LIST) do
		kv(player):set("done-" .. def.id, false)
		kv(player):set("pois-" .. def.id, "")
	end
	kv(player):set("map-percent", 0)
	sessions[player:getGuid()] = nil
	player:sendDiscoveryCurrentArea(0)
	DiscoverySystem.sendDiscoveryData(player)
end

function DiscoverySystem.status(player)
	-- summary per main area + detail lines only for started-but-unfinished subareas
	local lines = {}
	local perMain = {}
	local inProgress = {}
	for _, def in ipairs(SUBAREA_LIST) do
		if isDiscoverable(def) then
			local pm = perMain[def.mainArea]
			if not pm then
				pm = { total = 0, done = 0 }
				perMain[def.mainArea] = pm
			end
			pm.total = pm.total + 1
			if isCompleted(player, def.id) then
				pm.done = pm.done + 1
			else
				local pois = deserializePois(kv(player):get("pois-" .. def.id))
				if pois then
					inProgress[#inProgress + 1] = string.format("  %s (%d): %d/%d", def.name, def.id, countFound(pois), #pois)
				end
			end
		end
	end
	local mainIds = {}
	for mainId in pairs(perMain) do
		mainIds[#mainIds + 1] = mainId
	end
	table.sort(mainIds)
	for _, mainId in ipairs(mainIds) do
		local pm = perMain[mainId]
		lines[#lines + 1] = string.format("%s: %d/%d subareas done", MAIN_AREAS[mainId] or ("area " .. mainId), pm.done, pm.total)
	end
	if #inProgress > 0 then
		lines[#lines + 1] = "In progress:"
		for _, l in ipairs(inProgress) do
			lines[#lines + 1] = l
		end
	end
	return lines
end

function DiscoverySystem.dumpPois(player)
	local session = sessions[player:getGuid()]
	if session and session.pois then
		logger.info("[disco] {} subarea {} pois: {}", player:getName(), session.subId, serializePois(session.pois))
		return true
	end
	return false
end

local discoveryTick = GlobalEvent("DiscoverySystemTick")

function discoveryTick.onThink(interval)
	for _, player in ipairs(Game.getPlayers()) do
		DiscoverySystem.tick(player)
	end
	return true
end

discoveryTick:interval(1000)
discoveryTick:register()

local discoveryLogin = CreatureEvent("DiscoverySystemLogin")
discoveryLogin:type("login")

--- Login and headless-body reclaim (Alts.onClientAttached) both land here.
function DiscoverySystem.onClientAttached(player)
	if not hasClient(player) then
		return
	end
	local store = kv(player)
	if store:get("geom-version") ~= GEOMETRY_VERSION then
		for _, def in ipairs(SUBAREA_LIST) do
			store:set("pois-" .. def.id, "")
		end
		store:set("geom-version", GEOMETRY_VERSION)
	end
	DiscoverySystem.sendDiscoveryData(player)
	DiscoverySystem.sendDonations(player)
end

function discoveryLogin.onLogin(player)
	DiscoverySystem.onClientAttached(player)
	return true
end

discoveryLogin:register()

local discoveryStartup = GlobalEvent("DiscoverySystemStartup")

function discoveryStartup.onStartup()
	reportUnusableSubareas()
	local rects, names = DiscoverySystem.applyImprovedRespawnZones()
	if rects > 0 then
		logger.info("[DiscoverySystem] improved respawn active in: {} ({} rects)", table.concat(names, ", "), rects)
	end
	return true
end

discoveryStartup:register()

local discoveryLogout = CreatureEvent("DiscoverySystemLogout")
discoveryLogout:type("logout")

function discoveryLogout.onLogout(player)
	local session = sessions[player:getGuid()]
	if session then
		clearIdlePoiEffects(player, session)
	end
	sessions[player:getGuid()] = nil
	return true
end

discoveryLogout:register()
