-- Lobby records: identity, members, settings, bonuses. Persisted in global KV by lobby id;
-- every player belongs to exactly one lobby (a private personal lobby by default).
LobbyStore = LobbyStore or {}

-- lobbyId -> record
local records = {}
-- member guid -> lobbyId
local indexByGuid = {}
-- lobbyId -> { state, call, ... } (never persisted)
local runtimeById = {}
local loaded = false

local function recordsKv()
	if not kv or not kv.scoped then
		return nil
	end
	return kv.scoped("lobby"):scoped("records")
end

local function metaKv()
	if not kv or not kv.scoped then
		return nil
	end
	return kv.scoped("lobby")
end

local function decode(raw)
	if type(raw) == "table" then
		return raw
	end
	if type(raw) == "string" and raw ~= "" then
		local ok, decoded = pcall(JsonParser.decode, raw)
		if ok and type(decoded) == "table" then
			return decoded
		end
	end
	return nil
end

local function sanitizeTitle(raw, fallback)
	local title = tostring(raw or ""):gsub("[^\32-\126]", ""):gsub("^%s+", ""):gsub("%s+$", "")
	if #title > LobbyConfig.TITLE_MAX_LEN then
		title = title:sub(1, LobbyConfig.TITLE_MAX_LEN)
	end
	if title == "" then
		return fallback or ""
	end
	return title
end
LobbyStore.sanitizeTitle = sanitizeTitle

local function normalizeRecord(raw)
	if type(raw) ~= "table" then
		return nil
	end
	local id = math.floor(tonumber(raw.id) or 0)
	local hostGuid = math.floor(tonumber(raw.hostGuid) or 0)
	if id <= 0 or hostGuid <= 0 then
		return nil
	end
	local record = {
		id = id,
		title = sanitizeTitle(raw.title, ""),
		hostGuid = hostGuid,
		hostName = tostring(raw.hostName or ""),
		hostAccountId = math.floor(tonumber(raw.hostAccountId) or 0),
		members = {},
		size = math.max(1, math.min(LobbyConfig.MAX_MEMBERS, math.floor(tonumber(raw.size) or LobbyConfig.MAX_MEMBERS))),
		public = raw.public == true,
		expeditionId = tostring(raw.expeditionId or ""),
		role = tostring(raw.role or ""),
		expeditionName = tostring(raw.expeditionName or ""),
		creatureId = tonumber(raw.creatureId),
		levelMin = math.max(1, math.floor(tonumber(raw.levelMin) or 1)),
		levelMax = math.max(1, math.floor(tonumber(raw.levelMax) or 9999)),
		bossDifficulty = raw.bossDifficulty,
		bonuses = type(raw.bonuses) == "table" and raw.bonuses or nil,
		created = math.floor(tonumber(raw.created) or os.time()),
	}
	local seen = {}
	for _, m in ipairs(type(raw.members) == "table" and raw.members or {}) do
		local guid = math.floor(tonumber(m.guid) or 0)
		if guid > 0 and not seen[guid] then
			seen[guid] = true
			record.members[#record.members + 1] = {
				guid = guid,
				name = tostring(m.name or ""),
				accountId = math.floor(tonumber(m.accountId) or 0),
				level = tonumber(m.level) or 0,
				vocation = tostring(m.vocation or ""),
				outfit = type(m.outfit) == "table" and m.outfit or nil,
			}
		end
	end
	if not seen[hostGuid] then
		table.insert(record.members, 1, {
			guid = hostGuid,
			name = record.hostName,
			accountId = record.hostAccountId,
			level = 0,
			vocation = "",
		})
	end
	return record
end

local function indexRecord(record)
	for guid, id in pairs(indexByGuid) do
		if id == record.id then
			indexByGuid[guid] = nil
		end
	end
	for _, m in ipairs(record.members) do
		indexByGuid[m.guid] = record.id
	end
end

local function persist(record)
	local store = recordsKv()
	if not store then
		return
	end
	store:set(tostring(record.id), JsonParser.encode(record))
end

local function ensureLoaded()
	if loaded then
		return
	end
	loaded = true
	local store = recordsKv()
	if not store or not store.keys then
		return
	end
	local keys = store:keys("")
	if type(keys) ~= "table" then
		return
	end
	local list = {}
	for _, key in ipairs(keys) do
		local record = normalizeRecord(decode(store:get(key)))
		if record and tostring(record.id) == tostring(key) then
			list[#list + 1] = record
		else
			store:remove(key)
		end
	end
	-- Newest lobby wins when a guid ended up in two records.
	table.sort(list, function(a, b)
		return a.created > b.created
	end)
	for _, record in ipairs(list) do
		local kept = {}
		for _, m in ipairs(record.members) do
			if not indexByGuid[m.guid] then
				kept[#kept + 1] = m
			end
		end
		record.members = kept
		local hostKept = false
		for _, m in ipairs(kept) do
			if m.guid == record.hostGuid then
				hostKept = true
			end
		end
		if hostKept then
			records[record.id] = record
			indexRecord(record)
		else
			store:remove(tostring(record.id))
		end
	end
	logger.info("[Lobby] loaded {} lobby record(s)", #list)
end

local function nextLobbyId()
	local meta = metaKv()
	local current = 0
	if meta then
		current = math.floor(tonumber(meta:get("next_id")) or 0)
	end
	for id in pairs(records) do
		if id > current then
			current = id
		end
	end
	current = current + 1
	if meta then
		meta:set("next_id", tostring(current))
	end
	return current
end

local function vocationName(player)
	return Alts and Alts.vocationName and Alts.vocationName(player) or ""
end

local function snapshotProfile(entry, player)
	if not entry or not player then
		return
	end
	entry.name = player:getName()
	entry.accountId = player:getAccountId()
	entry.level = player:getLevel() or entry.level
	entry.vocation = vocationName(player)
	if Alts and Alts.outfitFrom then
		entry.outfit = Alts.outfitFrom(player) or entry.outfit
	end
end
LobbyStore.snapshotProfile = snapshotProfile

function LobbyStore.save(record)
	if not record then
		return
	end
	ensureLoaded()
	records[record.id] = record
	indexRecord(record)
	persist(record)
end

function LobbyStore.get(lobbyId)
	ensureLoaded()
	return records[math.floor(tonumber(lobbyId) or 0)]
end

function LobbyStore.getByGuid(guid)
	ensureLoaded()
	local id = indexByGuid[math.floor(tonumber(guid) or 0)]
	return id and records[id] or nil
end

function LobbyStore.getForPlayer(player)
	if not player then
		return nil
	end
	return LobbyStore.getByGuid(player:getGuid())
end

function LobbyStore.all()
	ensureLoaded()
	local out = {}
	for _, record in pairs(records) do
		out[#out + 1] = record
	end
	table.sort(out, function(a, b)
		return a.id < b.id
	end)
	return out
end

function LobbyStore.runtime(record)
	if not record then
		return {}
	end
	local rt = runtimeById[record.id]
	if not rt then
		rt = { state = LobbyConfig.STATE_LOBBY }
		runtimeById[record.id] = rt
	end
	return rt
end

function LobbyStore.member(record, guid)
	if not record then
		return nil
	end
	guid = math.floor(tonumber(guid) or 0)
	for i, m in ipairs(record.members) do
		if m.guid == guid then
			return m, i
		end
	end
	return nil
end

function LobbyStore.isHost(record, player)
	return record ~= nil and player ~= nil and record.hostGuid == player:getGuid()
end

--- Alt: an alt of the host's account that is not the host and has no live UI client.
function LobbyStore.isAltEntry(record, entry)
	if not record or not entry or entry.guid == record.hostGuid then
		return false
	end
	if record.hostAccountId <= 0 or entry.accountId ~= record.hostAccountId then
		return false
	end
	return not (Alts and Alts.isRealOnlineClient and Alts.isRealOnlineClient(entry.guid))
end

function LobbyStore.humans(record)
	local out = {}
	for _, m in ipairs((record and record.members) or {}) do
		if not LobbyStore.isAltEntry(record, m) then
			out[#out + 1] = m
		end
	end
	return out
end

function LobbyStore.alts(record)
	local out = {}
	for _, m in ipairs((record and record.members) or {}) do
		if LobbyStore.isAltEntry(record, m) then
			out[#out + 1] = m
		end
	end
	return out
end

function LobbyStore.altNames(record)
	local names = {}
	for _, m in ipairs(LobbyStore.alts(record)) do
		names[#names + 1] = m.name
	end
	return names
end

function LobbyStore.memberNames(record, exceptGuid)
	local names = {}
	for _, m in ipairs((record and record.members) or {}) do
		if m.guid ~= exceptGuid then
			names[#names + 1] = m.name
		end
	end
	return names
end

function LobbyStore.freeSlots(record)
	if not record then
		return 0
	end
	return math.max(0, record.size - #record.members)
end

--- Personal lobby: private, 1 slot, only the owner.
function LobbyStore.isPristine(record)
	if not record or #record.members ~= 1 or record.public then
		return false
	end
	return LobbyBonus == nil or not LobbyBonus.hasActive(record)
end

--- Create a new lobby hosted by `host` (host must not be in another lobby).
function LobbyStore.create(host, opts)
	if not host then
		return nil
	end
	ensureLoaded()
	opts = opts or {}
	local entry = { guid = host:getGuid() }
	snapshotProfile(entry, host)
	local record = {
		id = nextLobbyId(),
		title = sanitizeTitle(opts.title, host:getName() .. "'s lobby"),
		hostGuid = host:getGuid(),
		hostName = host:getName(),
		hostAccountId = host:getAccountId(),
		members = { entry },
		size = math.max(1, math.min(LobbyConfig.MAX_MEMBERS, math.floor(tonumber(opts.size) or LobbyConfig.MAX_MEMBERS))),
		public = opts.public == true,
		expeditionId = "",
		role = "",
		expeditionName = "",
		levelMin = 1,
		levelMax = 9999,
		created = os.time(),
	}
	LobbyStore.save(record)
	return record
end

--- Remove a record entirely (members are dropped from the index).
function LobbyStore.delete(record)
	if not record then
		return
	end
	ensureLoaded()
	for guid, id in pairs(indexByGuid) do
		if id == record.id then
			indexByGuid[guid] = nil
		end
	end
	records[record.id] = nil
	runtimeById[record.id] = nil
	local store = recordsKv()
	if store then
		store:remove(tostring(record.id))
	end
end

--- Add a member entry. `src` is a Player or { guid, name, accountId }.
function LobbyStore.addMember(record, src)
	if not record or not src then
		return false
	end
	local entry
	if type(src) == "userdata" then
		entry = { guid = src:getGuid() }
		snapshotProfile(entry, src)
	else
		entry = {
			guid = math.floor(tonumber(src.guid) or 0),
			name = tostring(src.name or ""),
			accountId = math.floor(tonumber(src.accountId) or 0),
			level = tonumber(src.level) or 0,
			vocation = tostring(src.vocation or ""),
			outfit = src.outfit,
		}
	end
	if entry.guid <= 0 or LobbyStore.member(record, entry.guid) then
		return false
	end
	record.members[#record.members + 1] = entry
	LobbyStore.save(record)
	return true
end

function LobbyStore.removeMember(record, guid)
	local _, index = LobbyStore.member(record, guid)
	if not index then
		return false
	end
	table.remove(record.members, index)
	indexByGuid[math.floor(tonumber(guid) or 0)] = nil
	LobbyStore.save(record)
	return true
end

--- Make `entry` host. Callers handle alts of the previous host account.
function LobbyStore.setHost(record, entry)
	if not record or not entry then
		return
	end
	record.hostGuid = entry.guid
	record.hostName = entry.name
	record.hostAccountId = entry.accountId
	-- Host row first keeps slot order stable for the UI.
	local _, index = LobbyStore.member(record, entry.guid)
	if index and index > 1 then
		table.remove(record.members, index)
		table.insert(record.members, 1, entry)
	end
	LobbyStore.save(record)
end

--- Refresh cached profile for an online member (level/vocation/outfit for offline wire).
function LobbyStore.touchMember(player)
	local record = LobbyStore.getForPlayer(player)
	if not record then
		return nil
	end
	local entry = LobbyStore.member(record, player:getGuid())
	if entry then
		snapshotProfile(entry, player)
		if record.hostGuid == entry.guid then
			record.hostName = entry.name
			record.hostAccountId = entry.accountId
		end
		LobbyStore.save(record)
	end
	return record
end
