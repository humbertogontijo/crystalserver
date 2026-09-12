ListingsStore = ListingsStore or {}

-- hostGuid → listing
local listingsByHostGuid = {}
-- joinerGuid → { hostGuid, created }
local joinRequestsByJoiner = {}
-- playerGuid → hostGuid for accepted members and hosts (one team at a time).
local membershipByPlayerGuid = {}

local TEAM_CHANNEL_CLOSED =
	"The channel has been closed. Either the corresponding team has been unlisted or you have been rejected by the team leader."

local function reindexListingMembership(listing)
	if not listing or not listing.hostGuid then
		return
	end
	local hostGuid = listing.hostGuid
	for guid, indexedHost in pairs(membershipByPlayerGuid) do
		if indexedHost == hostGuid then
			membershipByPlayerGuid[guid] = nil
		end
	end
	membershipByPlayerGuid[hostGuid] = hostGuid
	for _, m in ipairs(listing.members or {}) do
		local guid = tonumber(m.guid) or 0
		if guid > 0 and m.status == SocialConfig.MEMBER_STATUS_ACCEPTED then
			membershipByPlayerGuid[guid] = hostGuid
		end
	end
end

local function clearMembershipIndexForHost(hostGuid)
	hostGuid = tonumber(hostGuid) or 0
	if hostGuid <= 0 then
		return
	end
	for guid, indexedHost in pairs(membershipByPlayerGuid) do
		if indexedHost == hostGuid then
			membershipByPlayerGuid[guid] = nil
		end
	end
end

local function kvGet(player, key)
	local kv = player and player:kv()
	if not kv then
		return nil
	end
	return kv:get(key)
end

local function kvSet(player, key, value)
	local kv = player and player:kv()
	if not kv then
		return false
	end
	kv:set(key, value)
	return true
end

local function decodeStored(stored)
	if type(stored) == "string" and stored ~= "" then
		local decoded = SocialJson.decode(stored)
		if type(decoded) == "table" then
			return decoded
		end
	elseif type(stored) == "table" then
		return stored
	end
	return nil
end

local function persistListing(player, listing)
	if not player then
		return false
	end
	local key = SocialConfig.KV_LISTING
	if not listing then
		return kvSet(player, key, "")
	end
	return kvSet(player, key, SocialJson.encode(listing))
end

--- Write current in-memory listing for a host (online preferred).
local function saveListing(listing)
	if not listing then
		return
	end
	reindexListingMembership(listing)
	local host = Player(listing.hostGuid) or Player(listing.hostName)
	if not host and TeamStore and TeamStore.findOnlinePlayerByGuid then
		host = TeamStore.findOnlinePlayerByGuid(listing.hostGuid)
	end
	if host then
		persistListing(host, listing)
	end
end

local function createTeamChannel(host)
	if not host then
		return
	end
	pcall(function()
		host:createTeamChannel()
	end)
end

local function inviteToTeamChannel(host, member)
	if not host or not member or host:getGuid() == member:getGuid() then
		return
	end
	pcall(function()
		host:inviteToTeamChannel(member)
	end)
end

local function excludeFromTeamChannel(host, member)
	if not host or not member or host:getGuid() == member:getGuid() then
		return
	end
	pcall(function()
		host:excludeFromTeamChannel(member)
	end)
end

local function closeTeamChannel(host)
	if not host then
		return
	end
	pcall(function()
		host:closeTeamChannel(TEAM_CHANNEL_CLOSED)
	end)
end

local function vocationKey(player)
	local voc = player and player:getVocation()
	if not voc then
		return "other"
	end
	local ok, name = pcall(function()
		return voc:getName()
	end)
	if not ok or type(name) ~= "string" then
		return "other"
	end
	local lower = name:lower()
	if lower:find("knight", 1, true) then
		return "knight"
	elseif lower:find("paladin", 1, true) then
		return "paladin"
	elseif lower:find("sorcerer", 1, true) then
		return "sorcerer"
	elseif lower:find("druid", 1, true) then
		return "druid"
	elseif lower:find("monk", 1, true) then
		return "monk"
	end
	return lower
end

local function outfitFromPlayer(player)
	if not player or not player.getOutfit then
		return nil
	end
	local ok, look = pcall(function()
		return player:getOutfit()
	end)
	if not ok or type(look) ~= "table" then
		return nil
	end
	return {
		type = look.lookType or look.type or 0,
		head = look.lookHead or look.head or 0,
		body = look.lookBody or look.body or 0,
		legs = look.lookLegs or look.legs or 0,
		feet = look.lookFeet or look.feet or 0,
		addons = look.lookAddons or look.addons or 0,
	}
end

local function memberWire(player, status, ready)
	if not player then
		return nil
	end
	local wire = {
		guid = player:getGuid(),
		name = player:getName(),
		level = player:getLevel() or 0,
		vocation = vocationKey(player),
		status = status or SocialConfig.MEMBER_STATUS_ACCEPTED,
		ready = ready == true,
	}
	local outfit = outfitFromPlayer(player)
	if outfit then
		wire.outfit = outfit
		wire.lookType = outfit.type
		wire.addon = outfit.addons
	end
	return wire
end

local function listingCreatureId(listing)
	if not listing then
		return nil
	end
	local stored = tonumber(listing.creatureId)
	if stored and stored > 0 then
		return stored
	end
	local id = listing.expeditionId
	if not id or id == "" or not ExpeditionConfig or not ExpeditionConfig.getById then
		return nil
	end
	local role = listing.role
	if role ~= "boss" and role ~= "monster" then
		role = nil
	end
	local entry = ExpeditionConfig.getById(id, role)
	if not entry then
		entry = ExpeditionConfig.getById(id, "boss") or ExpeditionConfig.getById(id, "monster")
	end
	if not entry and listing.expeditionName and ExpeditionConfig.Catalog then
		local want = tostring(listing.expeditionName):lower()
		for _, e in ipairs(ExpeditionConfig.Catalog) do
			if tostring(e.name or ""):lower() == want then
				entry = e
				break
			end
		end
	end
	if not entry then
		return nil
	end
	local cid = tonumber(entry.creatureId)
	if (not cid or cid <= 0) and type(entry.creatureIds) == "table" then
		cid = tonumber(entry.creatureIds[1])
	end
	if (not cid or cid <= 0) and type(entry.creatures) == "table" and entry.creatures[1] then
		cid = tonumber(entry.creatures[1].creatureId)
	end
	return cid and cid > 0 and cid or nil
end

local function acceptedMemberVocations(listing)
	local set = {}
	local out = {}
	for _, m in ipairs((listing and listing.members) or {}) do
		if m.status == SocialConfig.MEMBER_STATUS_ACCEPTED and type(m.vocation) == "string" and m.vocation ~= "" then
			local key = m.vocation:lower()
			if not set[key] then
				set[key] = true
				out[#out + 1] = key
			end
		end
	end
	return out
end

local function clearMembersReady(listing, exceptHost)
	if not listing then
		return
	end
	for _, m in ipairs(listing.members or {}) do
		if not exceptHost or m.guid ~= listing.hostGuid then
			m.ready = false
		else
			m.ready = true
		end
	end
end

local function listingMembersFromRoster(host, rosterMembers, priorMembers)
	local out = {}
	local seen = {}
	for _, entry in ipairs(rosterMembers or {}) do
		local name = entry and entry.name
		if name then
			local p = Player(name) or (Game.getOfflinePlayer and Game.getOfflinePlayer(name))
			if p then
				local wire = memberWire(p, SocialConfig.MEMBER_STATUS_ACCEPTED)
				if wire then
					out[#out + 1] = wire
					seen[wire.guid] = true
					if wire.name then
						seen[wire.name:lower()] = true
					end
				end
			end
		end
	end
	for _, m in ipairs(priorMembers or {}) do
		if m.status == SocialConfig.MEMBER_STATUS_PENDING then
			if not seen[m.guid] and not (m.name and seen[m.name:lower()]) then
				out[#out + 1] = {
					guid = m.guid,
					name = m.name,
					level = m.level,
					vocation = m.vocation,
					status = m.status,
				}
			end
		end
	end
	if host and #out == 0 then
		local hostWire = memberWire(host, SocialConfig.MEMBER_STATUS_ACCEPTED)
		if hostWire then
			out[#out + 1] = hostWire
		end
	end
	return out
end

local function maxListingSize()
	local teamMax = (TeamConfig and TeamConfig.MAX_MEMBERS) or 4
	local socialMax = SocialConfig.MAX_LISTING_SIZE or 4
	return math.min(teamMax, socialMax)
end

--- Unique occupied slots: account roster + accepted/pending listing members.
local function listingOccupancy(listing)
	local seen = {}
	local count = 0
	local function addName(name)
		if type(name) ~= "string" or name == "" then
			return
		end
		local key = name:lower()
		if seen[key] then
			return
		end
		seen[key] = true
		count = count + 1
	end

	if TeamStore and TeamStore.getMembers and listing then
		local host = nil
		if listing.hostGuid and listing.hostGuid > 0 then
			host = Player(listing.hostGuid)
		end
		if not host and listing.hostName then
			host = Player(listing.hostName)
		end
		if host then
			for _, entry in ipairs(TeamStore.getMembers(host) or {}) do
				addName(entry.name)
			end
		end
	end

	for _, m in ipairs((listing and listing.members) or {}) do
		if m.status == SocialConfig.MEMBER_STATUS_ACCEPTED then
			addName(m.name)
		end
	end

	return count
end

local function refreshFreeSlots(listing)
	if not listing then
		return
	end
	local size = math.max(1, math.min(tonumber(listing.size) or maxListingSize(), maxListingSize()))
	listing.size = size
	listing.freeSlots = math.max(0, size - listingOccupancy(listing))
end

local function listingWire(listing)
	if not listing then
		return nil
	end
	refreshFreeSlots(listing)
	local vocations = {}
	for _, v in ipairs(listing.vocations or {}) do
		vocations[#vocations + 1] = v
	end
	local members = {}
	for _, m in ipairs(listing.members or {}) do
		local isLeader = m.guid == listing.hostGuid
		local row = {
			guid = m.guid,
			name = m.name,
			level = m.level,
			vocation = m.vocation,
			status = m.status,
			isLeader = isLeader,
			-- Host is always treated as ready for Start gating / lobby UI.
			ready = isLeader or m.ready == true,
		}
		if type(m.outfit) == "table" then
			row.outfit = m.outfit
			row.lookType = m.outfit.type or m.lookType
			row.addon = m.outfit.addons or m.addon
		elseif m.lookType then
			row.lookType = m.lookType
			row.addon = m.addon
		end
		members[#members + 1] = row
	end
	local creatureId = listingCreatureId(listing)
	return {
		hostGuid = listing.hostGuid,
		hostName = listing.hostName,
		expeditionId = listing.expeditionId or "",
		expeditionName = listing.expeditionName or "Unspecified",
		role = listing.role or SocialConfig.ROLE_OTHER,
		creatureId = creatureId,
		levelMin = listing.levelMin or 1,
		levelMax = listing.levelMax or 9999,
		vocations = vocations,
		size = listing.size or SocialConfig.MAX_LISTING_SIZE,
		freeSlots = listing.freeSlots or 0,
		acceptParty = listing.acceptParty == true,
		-- Instant join: public lobbies always accept without host confirmation.
		openJoin = true,
		public = listing.public == true,
		startImmediately = listing.startImmediately ~= false,
		members = members,
		created = listing.created or 0,
		status = listing.freeSlots > 0 and "open" or "full",
	}
end

function ListingsStore.getByHostGuid(hostGuid)
	return listingsByHostGuid[tonumber(hostGuid) or 0]
end

function ListingsStore.getByHost(player)
	if not player then
		return nil
	end
	return listingsByHostGuid[player:getGuid()]
end

--- Listing where player is an accepted member (not host).
function ListingsStore.findMembership(player)
	if not player then
		return nil
	end
	local guid = tonumber(player:getGuid()) or 0
	local hostGuid = ListingsStore.getMembershipHostGuid(guid)
	if not hostGuid or hostGuid == guid then
		return nil
	end
	local listing = listingsByHostGuid[hostGuid]
	if not listing then
		return nil
	end
	for _, m in ipairs(listing.members or {}) do
		if tonumber(m.guid) == guid and m.status == SocialConfig.MEMBER_STATUS_ACCEPTED then
			return {
				hostGuid = listing.hostGuid,
				hostName = listing.hostName,
				listing = listing,
			}
		end
	end
	return nil
end

--- Online listing host for the same account (companions see the host's assembled team).
function ListingsStore.findHostForAccount(accountId, excludeGuid)
	accountId = tonumber(accountId) or 0
	excludeGuid = tonumber(excludeGuid) or 0
	if accountId <= 0 then
		return nil
	end
	for _, p in ipairs(Game.getPlayers()) do
		if p:getAccountId() == accountId and listingsByHostGuid[p:getGuid()] then
			if excludeGuid <= 0 or p:getGuid() ~= excludeGuid then
				return p
			end
		end
	end
	return nil
end

--- Which live team this player currently belongs to (host or accepted/pending member).
function ListingsStore.getMembershipHostGuid(playerOrGuid)
	local guid = playerOrGuid
	if type(playerOrGuid) == "userdata" and playerOrGuid.getGuid then
		guid = playerOrGuid:getGuid()
	end
	guid = tonumber(guid) or 0
	if guid <= 0 then
		return nil
	end
	local indexed = membershipByPlayerGuid[guid]
	if indexed and listingsByHostGuid[indexed] then
		return indexed
	end
	if listingsByHostGuid[guid] then
		return guid
	end
	for hostGuid, listing in pairs(listingsByHostGuid) do
		if listing then
			for _, m in ipairs(listing.members or {}) do
				if tonumber(m.guid) == guid then
					return hostGuid
				end
			end
		end
	end
	return nil
end

--- Remove player from every live listing except keepHostGuid (nil = leave all).
function ListingsStore.leaveAllOtherTeams(player, keepHostGuid)
	if not player then
		return
	end
	local guid = player:getGuid()
	keepHostGuid = tonumber(keepHostGuid) or 0
	if listingsByHostGuid[guid] and guid ~= keepHostGuid then
		ListingsStore.clearHost(player, true)
	end
	local hostGuids = {}
	for hostGuid, listing in pairs(listingsByHostGuid) do
		if hostGuid ~= keepHostGuid and hostGuid ~= guid then
			for _, m in ipairs(listing.members or {}) do
				if tonumber(m.guid) == guid then
					hostGuids[#hostGuids + 1] = hostGuid
					break
				end
			end
		end
	end
	for _, hostGuid in ipairs(hostGuids) do
		ListingsStore.kickMemberByGuid(hostGuid, guid)
	end
	joinRequestsByJoiner[guid] = nil
end

function ListingsStore.isListingMember(hostGuid, joinerGuid)
	local listing = listingsByHostGuid[tonumber(hostGuid) or 0]
	if not listing then
		return false
	end
	joinerGuid = tonumber(joinerGuid) or 0
	for _, m in ipairs(listing.members or {}) do
		if m.guid == joinerGuid and m.status == SocialConfig.MEMBER_STATUS_ACCEPTED then
			return true
		end
	end
	return false
end

function ListingsStore.getAcceptedMemberNames(hostGuid)
	local listing = listingsByHostGuid[tonumber(hostGuid) or 0]
	local names = {}
	if not listing then
		return names
	end
	for _, m in ipairs(listing.members or {}) do
		if m.status == SocialConfig.MEMBER_STATUS_ACCEPTED and m.guid ~= listing.hostGuid then
			names[#names + 1] = m.name
		end
	end
	return names
end

function ListingsStore.hasPendingMembers(hostOrGuid)
	local listing = nil
	if type(hostOrGuid) == "userdata" and hostOrGuid.getGuid then
		listing = listingsByHostGuid[hostOrGuid:getGuid()]
	else
		listing = listingsByHostGuid[tonumber(hostOrGuid) or 0]
	end
	if not listing then
		return false
	end
	for _, m in ipairs(listing.members or {}) do
		if m.status == SocialConfig.MEMBER_STATUS_PENDING then
			return true
		end
	end
	return false
end

--- Remove listing from the public in-memory map (optionally wipe KV).
--- @param clearPersist boolean when true, also erase KV so the team is disassembled
function ListingsStore.clearHost(player, clearPersist)
	if not player then
		return
	end
	closeTeamChannel(player)
	local guid = player:getGuid()
	clearMembershipIndexForHost(guid)
	listingsByHostGuid[guid] = nil
	-- Clear join requests targeting this host.
	for jGuid, req in pairs(joinRequestsByJoiner) do
		if req.hostGuid == guid then
			joinRequestsByJoiner[jGuid] = nil
		end
	end
	if clearPersist then
		persistListing(player, nil)
	end
end

--- Logout: hand off to an online same-account teammate when possible; otherwise park listing.
function ListingsStore.onLogout(player)
	if not player then
		return
	end
	local listing = listingsByHostGuid[player:getGuid()]
	if listing then
		persistListing(player, listing)

		local successor = ListingsStore.findOnlineAccountSuccessor(player, listing)
		if successor then
			-- Keep KV parked for adoptListing; drop live map so successor becomes sole host.
			closeTeamChannel(player)
			clearMembershipIndexForHost(player:getGuid())
			listingsByHostGuid[player:getGuid()] = nil

			-- Ensure successor can adopt: roster companion + controller pointer.
			if TeamManager and TeamManager.addCompanionToRoster then
				pcall(TeamManager.addCompanionToRoster, player, successor)
			end
			if TeamStore.setControllerPointer then
				TeamStore.setControllerPointer(successor, player:getGuid())
			end

			local ok = false
			if TeamManager and TeamManager.transferLeadership then
				ok = TeamManager.transferLeadership(successor, {
					force = true,
					fromHostGuid = player:getGuid(),
					reason = "logout",
				})
			elseif TeamStore and TeamStore.adoptAccountTeamLeadership then
				ok = TeamStore.adoptAccountTeamLeadership(successor, {
					force = true,
					fromHostGuid = player:getGuid(),
				})
				if ok then
					if SocialProtocol and SocialProtocol.sendMyListing then
						pcall(SocialProtocol.sendMyListing, successor)
					end
					if TeamProtocol and TeamProtocol.sendTeam then
						pcall(TeamProtocol.sendTeam, successor)
					end
				end
			end
			if ok then
				joinRequestsByJoiner[player:getGuid()] = nil
				return
			end
			-- Transfer failed — re-park as normal offline listing.
			listingsByHostGuid[player:getGuid()] = listing
			reindexListingMembership(listing)
		end
	end
	-- Keep KV; only remove from live Find list / team channel while offline.
	ListingsStore.clearHost(player, false)
	joinRequestsByJoiner[player:getGuid()] = nil
end

--- True when player is an accepted member (or host) on this host's live or parked listing.
function ListingsStore.playerOnHostListing(host, player)
	if not host or not player then
		return false
	end
	local listing = listingsByHostGuid[host:getGuid()]
	if not listing then
		listing = decodeStored(kvGet(host, SocialConfig.KV_LISTING))
	end
	if type(listing) ~= "table" then
		return false
	end
	local guid = tonumber(player:getGuid()) or 0
	local name = player:getName():lower()
	if tonumber(listing.hostGuid) == guid then
		return true
	end
	for _, m in ipairs(listing.members or {}) do
		if m.status == SocialConfig.MEMBER_STATUS_ACCEPTED then
			if tonumber(m.guid) == guid or (m.name and m.name:lower() == name) then
				return true
			end
		end
	end
	return false
end

--- Offline/online same-account host whose parked or live listing includes this player.
function ListingsStore.findParkedAccountHostForMember(player)
	if not player then
		return nil
	end
	local accountId = player:getAccountId()
	if not accountId or accountId <= 0 then
		return nil
	end
	local myGuid = player:getGuid()
	local resultId = db.storeQuery(
		"SELECT `id` FROM `players` WHERE `account_id` = "
			.. tonumber(accountId)
			.. " AND `deletion` = 0"
	)
	if not resultId then
		return nil
	end
	local found = nil
	repeat
		local guid = Result.getNumber(resultId, "id")
		if guid and guid ~= myGuid then
			local host = TeamStore and TeamStore.resolvePlayerByGuid and TeamStore.resolvePlayerByGuid(guid)
				or Player(guid)
				or (Game.getOfflinePlayer and Game.getOfflinePlayer(guid))
			if host and ListingsStore.playerOnHostListing(host, player) then
				found = host
				break
			end
		end
	until not Result.next(resultId)
	Result.free(resultId)
	return found
end

--- Online same-account teammate who can take over when the host logs out / detaches.
function ListingsStore.findOnlineAccountSuccessor(host, listing)
	if not host then
		return nil
	end
	listing = listing or listingsByHostGuid[host:getGuid()]
	local accountId = host:getAccountId()
	local hostGuid = host:getGuid()
	if not accountId or accountId <= 0 then
		return nil
	end

	local function isRealUi(p)
		if TeamManager and TeamManager.isRealUiClient then
			return TeamManager.isRealUiClient(p)
		end
		if not p then
			return false
		end
		if TeamManager and TeamManager.isCompanion and TeamManager.isCompanion(p) then
			return false
		end
		if p.isHeadless and p:isHeadless() then
			return false
		end
		if p.getProtocolVersion and p:getProtocolVersion() == 0 then
			return false
		end
		return true
	end

	local function isEligible(p)
		if not p or p:getGuid() == hostGuid then
			return false
		end
		if p:getAccountId() ~= accountId then
			return false
		end
		-- Prefer real UI clients; companion mark alone does not disqualify if they have a UI
		-- (attach clears the mark first — this covers race / lag cases).
		return isRealUi(p)
	end

	-- Prefer roster companions (account team order).
	if TeamStore and TeamStore.getMembers then
		for _, entry in ipairs(TeamStore.getMembers(host) or {}) do
			if entry.kind ~= TeamConfig.KIND_FRIEND and entry.name then
				local p = Player(entry.name)
				if isEligible(p) then
					return p
				end
			end
		end
	end

	-- Fall back to accepted listing members on the same account.
	for _, m in ipairs((listing and listing.members) or {}) do
		if m.status == SocialConfig.MEMBER_STATUS_ACCEPTED then
			local p = Player(m.guid) or Player(m.name)
			if isEligible(p) then
				return p
			end
		end
	end

	-- Any other online same-account character that points at this host.
	for _, p in ipairs(Game.getPlayers()) do
		if isEligible(p) then
			local pointer = TeamStore and TeamStore.getControllerPointer and TeamStore.getControllerPointer(p)
			if pointer == hostGuid then
				return p
			end
		end
	end
	return nil
end

--- Move assembled listing from offline host to the new same-account leader.
function ListingsStore.adoptListing(newHost, oldHost)
	if not newHost or not oldHost then
		return false
	end
	local oldGuid = oldHost:getGuid()
	local newGuid = newHost:getGuid()
	if oldGuid == newGuid then
		return false
	end

	local oldListing = listingsByHostGuid[oldGuid]
	if not oldListing then
		oldListing = decodeStored(kvGet(oldHost, SocialConfig.KV_LISTING))
	end
	if type(oldListing) ~= "table" or oldListing.hostGuid == nil then
		if listingsByHostGuid[newGuid] then
			ListingsStore.clearHost(newHost, true)
		end
		return false
	end

	if listingsByHostGuid[newGuid] then
		listingsByHostGuid[newGuid] = nil
		persistListing(newHost, nil)
	end

	local listing = {}
	for key, value in pairs(oldListing) do
		if key ~= "members" then
			listing[key] = value
		end
	end
	listing.hostGuid = newGuid
	listing.hostName = newHost:getName()

	local rosterMembers = TeamStore and TeamStore.getMembers and TeamStore.getMembers(newHost) or {}
	listing.members = listingMembersFromRoster(newHost, rosterMembers, oldListing.members)
	refreshFreeSlots(listing)

	listingsByHostGuid[oldGuid] = nil
	clearMembershipIndexForHost(oldGuid)
	persistListing(oldHost, nil)

	listingsByHostGuid[newGuid] = listing
	reindexListingMembership(listing)
	persistListing(newHost, listing)
	createTeamChannel(newHost)
	for _, m in ipairs(listing.members or {}) do
		if m.status == SocialConfig.MEMBER_STATUS_ACCEPTED and tonumber(m.guid) ~= newGuid then
			local member = Player(m.guid) or Player(m.name)
			if member then
				inviteToTeamChannel(newHost, member)
			end
		end
	end

	for _, req in pairs(joinRequestsByJoiner) do
		if req and req.hostGuid == oldGuid then
			req.hostGuid = newGuid
		end
	end

	return true
end

--- Login: restore assembled listing from KV into the live map.
function ListingsStore.onLogin(player)
	if not player then
		return nil
	end
	if TeamManager and TeamManager.transferLeadership then
		pcall(TeamManager.transferLeadership, player, { reason = "login" })
	elseif TeamStore and TeamStore.adoptAccountTeamLeadership then
		pcall(TeamStore.adoptAccountTeamLeadership, player)
	end

	-- If another same-account character hosts and this player is on that team, heal roster
	-- and do not restore a second listing for this character.
	local accountHost = ListingsStore.findHostForAccount(player:getAccountId(), player:getGuid())
	if accountHost then
		local onListing = ListingsStore.playerOnHostListing and ListingsStore.playerOnHostListing(accountHost, player)
		local onRoster = TeamStore and TeamStore.isOnControllerRoster and TeamStore.isOnControllerRoster(player, accountHost)
		if onListing or onRoster then
			if TeamManager and TeamManager.addCompanionToRoster then
				pcall(TeamManager.addCompanionToRoster, accountHost, player)
			end
			listingsByHostGuid[player:getGuid()] = nil
			persistListing(player, nil)
			return nil
		end
	end

	local pointerGuid = TeamStore and TeamStore.getControllerPointer and TeamStore.getControllerPointer(player)
	if pointerGuid and pointerGuid ~= player:getGuid() then
		local liveHost = nil
		if TeamStore and TeamStore.findOnlinePlayerByGuid then
			liveHost = TeamStore.findOnlinePlayerByGuid(pointerGuid)
		else
			liveHost = Player(pointerGuid)
		end
		if liveHost and not (TeamManager and TeamManager.isCompanion and TeamManager.isCompanion(liveHost)) then
			local onListing = ListingsStore.playerOnHostListing and ListingsStore.playerOnHostListing(liveHost, player)
			local onRoster = TeamStore and TeamStore.isOnControllerRoster and TeamStore.isOnControllerRoster(player, liveHost)
			if onListing or onRoster then
				listingsByHostGuid[player:getGuid()] = nil
				persistListing(player, nil)
				return nil
			end
		end
	end

	local raw = decodeStored(kvGet(player, SocialConfig.KV_LISTING))
	if type(raw) ~= "table" or raw.hostGuid == nil then
		-- Listing KV missing but account team still has members → recover assemble state
		-- so clients do not need to click Start Assembling again after reconnect.
		if pointerGuid and pointerGuid ~= player:getGuid() then
			return nil
		end
		-- Controller must be this player; never invent a listing for a companion.
		local controller = TeamStore and TeamStore.resolveTeamController and TeamStore.resolveTeamController(player)
		if controller and controller:getGuid() ~= player:getGuid() then
			return nil
		end
		local teamMembers = TeamStore and TeamStore.getMembers and TeamStore.getMembers(player) or nil
		if type(teamMembers) == "table" and #teamMembers > 1 then
			local members = listingMembersFromRoster(player, teamMembers, nil)
			raw = {
				hostGuid = player:getGuid(),
				hostName = player:getName(),
				expeditionId = "",
				expeditionName = "Unspecified",
				role = SocialConfig.ROLE_OTHER or "other",
				levelMin = 1,
				levelMax = 9999,
				vocations = SocialConfig.VOCATIONS,
				size = math.max(#teamMembers, 2),
				acceptParty = false,
				openJoin = false,
				startImmediately = true,
				members = members,
				created = os.time(),
			}
			refreshFreeSlots(raw)
			listingsByHostGuid[player:getGuid()] = raw
			reindexListingMembership(raw)
			persistListing(player, raw)
			createTeamChannel(player)
			return listingWire(raw)
		end
		return nil
	end
	-- Refresh host identity in case of rename.
	raw.hostGuid = player:getGuid()
	raw.hostName = player:getName()
	if type(raw.members) ~= "table" or #raw.members == 0 then
		raw.members = { memberWire(player, SocialConfig.MEMBER_STATUS_ACCEPTED) }
	else
		-- Ensure host row stays accepted + current name/level/voc.
		local foundHost = false
		for _, m in ipairs(raw.members) do
			if tonumber(m.guid) == raw.hostGuid or (m.name and m.name:lower() == player:getName():lower()) then
				m.guid = player:getGuid()
				m.name = player:getName()
				m.level = player:getLevel() or m.level or 0
				m.vocation = vocationKey(player)
				m.status = SocialConfig.MEMBER_STATUS_ACCEPTED
				foundHost = true
				break
			end
		end
		if not foundHost then
			table.insert(raw.members, 1, memberWire(player, SocialConfig.MEMBER_STATUS_ACCEPTED))
		end
	end
	refreshFreeSlots(raw)
	ListingsStore.leaveAllOtherTeams(player, player:getGuid())
	listingsByHostGuid[player:getGuid()] = raw
	reindexListingMembership(raw)
	persistListing(player, raw)
	createTeamChannel(player)
	for _, m in ipairs(raw.members or {}) do
		if m.status == SocialConfig.MEMBER_STATUS_ACCEPTED and tonumber(m.guid) ~= raw.hostGuid then
			local member = Player(m.guid) or Player(m.name)
			if member then
				inviteToTeamChannel(player, member)
			end
		end
	end
	return listingWire(raw)
end

local function normalizeVocations(raw)
	local out = {}
	local seen = {}
	if type(raw) ~= "table" then
		return SocialConfig.VOCATIONS
	end
	for _, v in ipairs(raw) do
		local key = tostring(v or ""):lower()
		if key ~= "" and not seen[key] then
			seen[key] = true
			out[#out + 1] = key
		end
	end
	if #out == 0 then
		return SocialConfig.VOCATIONS
	end
	return out
end

local function resolveRole(role, expeditionId)
	role = tostring(role or ""):lower()
	if role == SocialConfig.ROLE_RAID or role == SocialConfig.ROLE_BOSS or role == SocialConfig.ROLE_MONSTER or role == SocialConfig.ROLE_OTHER then
		return role
	end
	if ExpeditionConfig and ExpeditionConfig.getById and expeditionId and expeditionId ~= "" then
		local entry = ExpeditionConfig.getById(expeditionId)
		if entry then
			if entry.kind == "raid" then
				return SocialConfig.ROLE_RAID
			end
			if entry.role == "boss" or entry.kind == "boss" then
				return SocialConfig.ROLE_BOSS
			end
			return SocialConfig.ROLE_MONSTER
		end
	end
	return SocialConfig.ROLE_OTHER
end

local function resolveExpeditionName(expeditionId, fallback)
	if type(fallback) == "string" and fallback ~= "" then
		return fallback
	end
	if ExpeditionConfig and ExpeditionConfig.getById and expeditionId and expeditionId ~= "" then
		local entry = ExpeditionConfig.getById(expeditionId)
		if entry then
			return entry.name or tostring(expeditionId)
		end
	end
	if not expeditionId or expeditionId == "" then
		return "Unspecified"
	end
	return tostring(expeditionId)
end

function ListingsStore.publish(player, opts)
	if not player then
		return false, "No player."
	end
	-- Each character may host their own listing. leaveAllOtherTeams only drops this
	-- player's memberships elsewhere (same-account siblings keep their own teams).
	ListingsStore.leaveAllOtherTeams(player, player:getGuid())

	opts = opts or {}
	local size = math.floor(tonumber(opts.size) or maxListingSize())
	size = math.max(1, math.min(maxListingSize(), size))
	local levelMin = math.floor(tonumber(opts.levelMin) or 1)
	local levelMax = math.floor(tonumber(opts.levelMax) or 9999)
	if levelMax < levelMin then
		levelMax = levelMin
	end

	local expeditionId = tostring(opts.expeditionId or "")
	local role = resolveRole(opts.role, expeditionId)
	local creatureId = tonumber(opts.creatureId)
	if not creatureId or creatureId <= 0 then
		creatureId = nil
	end
	local listing = {
		hostGuid = player:getGuid(),
		hostName = player:getName(),
		expeditionId = expeditionId,
		expeditionName = resolveExpeditionName(expeditionId, opts.expeditionName),
		role = role,
		creatureId = creatureId,
		levelMin = levelMin,
		levelMax = levelMax,
		vocations = normalizeVocations(opts.vocations),
		size = size,
		acceptParty = opts.acceptParty == true,
		openJoin = true,
		public = opts.public == true,
		startImmediately = opts.startImmediately ~= false,
		members = { memberWire(player, SocialConfig.MEMBER_STATUS_ACCEPTED, true) },
		created = os.time(),
	}
	if not listing.creatureId then
		listing.creatureId = listingCreatureId(listing)
	end

	if listing.acceptParty then
		local party = player:getParty()
		if party then
			local members = party:getMembers() or {}
			local leader = party:getLeader()
			local candidates = {}
			if leader then
				candidates[#candidates + 1] = leader
			end
			for _, m in ipairs(members) do
				candidates[#candidates + 1] = m
			end
			for _, member in ipairs(candidates) do
				if member and member:getGuid() ~= player:getGuid() and #listing.members < size then
					local already = false
					for _, existing in ipairs(listing.members) do
						if existing.guid == member:getGuid() then
							already = true
							break
						end
					end
					if not already then
						ListingsStore.leaveAllOtherTeams(member, player:getGuid())
						listing.members[#listing.members + 1] =
							memberWire(member, SocialConfig.MEMBER_STATUS_ACCEPTED)
					end
				end
			end
		end
	end

	refreshFreeSlots(listing)
	listingsByHostGuid[player:getGuid()] = listing
	reindexListingMembership(listing)
	persistListing(player, listing)
	createTeamChannel(player)
	for _, m in ipairs(listing.members) do
		if m.status == SocialConfig.MEMBER_STATUS_ACCEPTED and m.guid ~= listing.hostGuid then
			local member = Player(m.guid) or Player(m.name)
			if member then
				inviteToTeamChannel(player, member)
			end
		end
	end
	return true, listingWire(listing)
end

function ListingsStore.stop(player)
	if not player then
		return false, "No player."
	end
	if not listingsByHostGuid[player:getGuid()] then
		-- Still clear any parked KV listing + team members.
		local parked = decodeStored(kvGet(player, SocialConfig.KV_LISTING))
		if not parked then
			return false, "No active listing."
		end
	end
	ListingsStore.clearHost(player, true)
	-- Disassemble account team (companions / friends) when unlisted.
	if TeamManager and TeamManager.disassemble then
		TeamManager.disassemble(player)
	elseif TeamStore and TeamStore.setMembers then
		TeamStore.setMembers(player, { { name = player:getName(), kind = "companion" } })
	end
	return true
end

function ListingsStore.update(player, opts)
	if not player then
		return false, "No player."
	end
	local listing = listingsByHostGuid[player:getGuid()]
	if not listing then
		return false, "No active listing."
	end
	opts = opts or {}
	if opts.size ~= nil then
		local size = math.floor(tonumber(opts.size) or listing.size or maxListingSize())
		listing.size = math.max(1, math.min(maxListingSize(), size))
	end
	if opts.levelMin ~= nil then
		listing.levelMin = math.floor(tonumber(opts.levelMin) or listing.levelMin or 1)
	end
	if opts.levelMax ~= nil then
		listing.levelMax = math.floor(tonumber(opts.levelMax) or listing.levelMax or 9999)
	end
	if listing.levelMax < listing.levelMin then
		listing.levelMax = listing.levelMin
	end
	if type(opts.vocations) == "table" then
		listing.vocations = normalizeVocations(opts.vocations)
	end
	if opts.startImmediately ~= nil then
		listing.startImmediately = opts.startImmediately == true
	end
	if opts.openJoin ~= nil then
		listing.openJoin = true
	end
	if opts.public ~= nil then
		listing.public = opts.public == true
	end
	if opts.acceptParty ~= nil then
		listing.acceptParty = opts.acceptParty == true
	end
	if opts.expeditionId ~= nil then
		local expeditionId = tostring(opts.expeditionId or "")
		local changedHunt = tostring(listing.expeditionId or "") ~= expeditionId
		listing.expeditionId = expeditionId
		listing.expeditionName = resolveExpeditionName(expeditionId, opts.expeditionName)
		listing.role = resolveRole(opts.role, expeditionId)
		if opts.creatureId ~= nil then
			local cid = tonumber(opts.creatureId)
			listing.creatureId = cid and cid > 0 and cid or nil
		elseif changedHunt then
			listing.creatureId = nil
		end
		if not listing.creatureId then
			listing.creatureId = listingCreatureId(listing)
		end
		if changedHunt then
			clearMembersReady(listing, true)
		end
		if opts.levelMin ~= nil then
			listing.levelMin = math.floor(tonumber(opts.levelMin) or listing.levelMin or 1)
		end
		if opts.levelMax ~= nil then
			listing.levelMax = math.floor(tonumber(opts.levelMax) or listing.levelMax or 9999)
		end
		if opts.size ~= nil then
			local size = math.floor(tonumber(opts.size) or listing.size or maxListingSize())
			listing.size = math.max(1, math.min(maxListingSize(), size))
		end
	elseif opts.creatureId ~= nil then
		local cid = tonumber(opts.creatureId)
		listing.creatureId = cid and cid > 0 and cid or nil
	end
	if opts.expeditionName ~= nil and opts.expeditionId == nil then
		listing.expeditionName = tostring(opts.expeditionName or listing.expeditionName or "Unspecified")
	end
	if opts.role ~= nil and opts.expeditionId == nil then
		listing.role = resolveRole(opts.role, listing.expeditionId)
	end
	listing.openJoin = true
	refreshFreeSlots(listing)
	persistListing(player, listing)
	return true, listingWire(listing)
end

local function matchesFilters(listing, filters)
	filters = filters or {}
	-- Level / size / start-time filters removed: Continue auto-creates listings from catalog.
	if type(filters.roles) == "table" and #filters.roles > 0 then
		local ok = false
		for _, r in ipairs(filters.roles) do
			if tostring(r):lower() == listing.role then
				ok = true
				break
			end
		end
		if not ok then
			return false
		end
	end
	-- Match against who is already in the lobby (accepted members), not advertised vocations.
	local memberVocs = acceptedMemberVocations(listing)
	local memberSet = {}
	for _, v in ipairs(memberVocs) do
		memberSet[v] = true
	end
	local include = filters.vocationsInclude or filters.vocations
	if type(include) == "table" and #include > 0 then
		local ok = false
		for _, v in ipairs(include) do
			if memberSet[tostring(v):lower()] then
				ok = true
				break
			end
		end
		if not ok then
			return false
		end
	end
	if type(filters.vocationsExclude) == "table" and #filters.vocationsExclude > 0 then
		for _, v in ipairs(filters.vocationsExclude) do
			if memberSet[tostring(v):lower()] then
				return false
			end
		end
	end
	local search = tostring(filters.search or ""):lower()
	if search ~= "" then
		local hay = (listing.expeditionName or "") .. " " .. (listing.hostName or "") .. " " .. (listing.expeditionId or "")
		if not hay:lower():find(search, 1, true) then
			return false
		end
	end
	local expeditionId = tostring(filters.expeditionId or "")
	if expeditionId ~= "" then
		if tostring(listing.expeditionId or "") ~= expeditionId then
			return false
		end
	end
	return true
end

function ListingsStore.list(filters)
	local out = {}
	for _, listing in pairs(listingsByHostGuid) do
		if listing.public == true and matchesFilters(listing, filters) then
			out[#out + 1] = listingWire(listing)
		end
	end
	table.sort(out, function(a, b)
		return (a.created or 0) > (b.created or 0)
	end)
	return out
end

function ListingsStore.requestJoin(player, hostGuidOrName)
	if not player then
		return false, "No player."
	end
	local host = nil
	local hostGuid = tonumber(hostGuidOrName) or 0
	if hostGuid > 0 then
		host = Player(hostGuid)
	else
		host = Player(tostring(hostGuidOrName or ""))
		if host then
			hostGuid = host:getGuid()
		end
	end
	local listing = listingsByHostGuid[hostGuid]
	if not listing then
		return false, "That team listing is no longer available."
	end
	if not host then
		host = Player(listing.hostName)
	end
	if not host then
		return false, "Host is offline."
	end
	if hostGuid == player:getGuid() then
		return false, "You are already the host."
	end

	local level = player:getLevel() or 0
	if level < (listing.levelMin or 1) or level > (listing.levelMax or 9999) then
		return false, "Your level does not match this team."
	end
	local myVoc = vocationKey(player)
	local vocOk = false
	for _, v in ipairs(listing.vocations or {}) do
		if v == myVoc then
			vocOk = true
			break
		end
	end
	if not vocOk and #(listing.vocations or {}) > 0 then
		return false, "Your vocation is not wanted on this team."
	end

	refreshFreeSlots(listing)
	if (listing.freeSlots or 0) <= 0 then
		return false, "This team is full."
	end

	for _, m in ipairs(listing.members) do
		if m.guid == player:getGuid() then
			if m.status == SocialConfig.MEMBER_STATUS_ACCEPTED then
				return false, "You are already on this team."
			end
			-- Stale pending from older clients: promote to accepted.
			if m.status == SocialConfig.MEMBER_STATUS_PENDING then
				m.status = SocialConfig.MEMBER_STATUS_ACCEPTED
				m.ready = false
				refreshFreeSlots(listing)
				inviteToTeamChannel(host, player)
				saveListing(listing)
				if TeamManager and TeamManager.syncRosterAfterListingAccept then
					pcall(TeamManager.syncRosterAfterListingAccept, host, player)
				end
				joinRequestsByJoiner[player:getGuid()] = nil
				return true, { accepted = true, listing = listingWire(listing), host = host }
			end
		end
	end

	-- One team at a time: drop any other live membership / own listing before joining.
	ListingsStore.leaveAllOtherTeams(player, hostGuid)

	-- Instant join: occupy the slot immediately (no host Accept).
	local wire = memberWire(player, SocialConfig.MEMBER_STATUS_ACCEPTED, false)
	listing.members[#listing.members + 1] = wire
	refreshFreeSlots(listing)
	inviteToTeamChannel(host, player)
	saveListing(listing)
	if TeamManager and TeamManager.syncRosterAfterListingAccept then
		pcall(TeamManager.syncRosterAfterListingAccept, host, player)
	end
	joinRequestsByJoiner[player:getGuid()] = nil
	return true, { accepted = true, listing = listingWire(listing), host = host }
end

function ListingsStore.isMemberReady(hostGuid, playerGuid)
	local listing = listingsByHostGuid[tonumber(hostGuid) or 0]
	if not listing then
		return false
	end
	playerGuid = tonumber(playerGuid) or 0
	if playerGuid <= 0 then
		return false
	end
	if playerGuid == listing.hostGuid then
		return true
	end
	for _, m in ipairs(listing.members or {}) do
		if m.guid == playerGuid and m.status == SocialConfig.MEMBER_STATUS_ACCEPTED then
			return m.ready == true
		end
	end
	return false
end

function ListingsStore.setReady(player, ready)
	if not player then
		return false, "No player."
	end
	local hostGuid = membershipByPlayerGuid[player:getGuid()]
	local listing = hostGuid and listingsByHostGuid[hostGuid] or nil
	if not listing then
		listing = listingsByHostGuid[player:getGuid()]
	end
	if not listing then
		return false, "You are not on a team listing."
	end
	local guid = player:getGuid()
	local member = nil
	for _, m in ipairs(listing.members or {}) do
		if m.guid == guid then
			member = m
			break
		end
	end
	if not member or member.status ~= SocialConfig.MEMBER_STATUS_ACCEPTED then
		return false, "You are not an accepted team member."
	end
	-- Host is always ready; ignore toggles that would clear it.
	if guid == listing.hostGuid then
		member.ready = true
	else
		member.ready = ready == true
	end
	-- Refresh outfit snapshot when marking ready.
	local outfit = outfitFromPlayer(player)
	if outfit then
		member.outfit = outfit
		member.lookType = outfit.type
		member.addon = outfit.addons
	end
	member.level = player:getLevel() or member.level
	member.vocation = vocationKey(player)
	saveListing(listing)
	return true, listingWire(listing)
end

-- Legacy: promote leftover pending members (instant join is the normal path).
function ListingsStore.acceptJoin(host, joinerGuidOrName)
	if not host then
		return false, "No host."
	end
	local listing = listingsByHostGuid[host:getGuid()]
	if not listing then
		return false, "No active listing."
	end
	local joinerGuid = tonumber(joinerGuidOrName) or 0
	local joinerName = nil
	if joinerGuid == 0 then
		local joiner = Player(tostring(joinerGuidOrName or ""))
		if joiner then
			joinerGuid = joiner:getGuid()
			joinerName = joiner:getName()
		end
	end
	local member = nil
	for _, m in ipairs(listing.members) do
		if m.guid == joinerGuid or (joinerName and m.name:lower() == joinerName:lower()) then
			member = m
			joinerGuid = m.guid
			break
		end
	end
	if not member then
		return false, "No pending join request."
	end
	if member.status == SocialConfig.MEMBER_STATUS_ACCEPTED then
		return true, { listing = listingWire(listing), joiner = Player(joinerGuid) or Player(member.name), member = member }
	end
	if member.status ~= SocialConfig.MEMBER_STATUS_PENDING then
		return false, "No pending join request."
	end
	refreshFreeSlots(listing)
	local accepted = 0
	for _, m in ipairs(listing.members) do
		if m.status == SocialConfig.MEMBER_STATUS_ACCEPTED then
			accepted = accepted + 1
		end
	end
	if accepted >= (listing.size or maxListingSize()) then
		return false, "Team is full."
	end
	if TeamStore and TeamStore.getMembers then
		local roster = TeamStore.getMembers(host) or {}
		local onRoster = false
		for _, entry in ipairs(roster) do
			if entry.name and member.name and entry.name:lower() == member.name:lower() then
				onRoster = true
				break
			end
		end
		if not onRoster and #roster >= ((TeamConfig and TeamConfig.MAX_MEMBERS) or 4) then
			return false, "Team is full."
		end
	end
	member.status = SocialConfig.MEMBER_STATUS_ACCEPTED
	member.ready = false
	local online = Player(joinerGuid) or Player(member.name)
	if online then
		ListingsStore.leaveAllOtherTeams(online, host:getGuid())
		member.level = online:getLevel() or member.level
		member.vocation = vocationKey(online)
		member.name = online:getName()
		local outfit = outfitFromPlayer(online)
		if outfit then
			member.outfit = outfit
			member.lookType = outfit.type
			member.addon = outfit.addons
		end
		inviteToTeamChannel(host, online)
	end
	joinRequestsByJoiner[joinerGuid] = nil
	refreshFreeSlots(listing)
	saveListing(listing)
	local joinerPlayer = online
	if not joinerPlayer and Game.getOfflinePlayer then
		joinerPlayer = Game.getOfflinePlayer(joinerGuid) or Game.getOfflinePlayer(member.name)
	end
	if TeamManager and TeamManager.syncRosterAfterListingAccept and joinerPlayer then
		pcall(TeamManager.syncRosterAfterListingAccept, host, joinerPlayer)
	end
	return true, { listing = listingWire(listing), joiner = online, member = member }
end

function ListingsStore.declineJoin(host, joinerGuidOrName)
	if not host then
		return false, "No host."
	end
	local listing = listingsByHostGuid[host:getGuid()]
	if not listing then
		return false, "No active listing."
	end
	local joinerGuid = tonumber(joinerGuidOrName) or 0
	local joinerName = tostring(joinerGuidOrName or ""):lower()
	local out = {}
	local declined = nil
	for _, m in ipairs(listing.members) do
		if m.guid == joinerGuid or m.name:lower() == joinerName then
			declined = m
			joinRequestsByJoiner[m.guid] = nil
		else
			out[#out + 1] = m
		end
	end
	if not declined then
		return false, "No pending join request."
	end
	listing.members = out
	refreshFreeSlots(listing)
	saveListing(listing)
	return true, { listing = listingWire(listing), member = declined }
end

function ListingsStore.leaveMember(player)
	if not player then
		return false, "No player."
	end
	local guid = player:getGuid()
	for _, listing in pairs(listingsByHostGuid) do
		if listing and listing.hostGuid ~= guid then
			for _, m in ipairs(listing.members or {}) do
				if m.guid == guid and m.status == SocialConfig.MEMBER_STATUS_ACCEPTED then
					local host = Player(listing.hostGuid) or Player(listing.hostName)
					local ok, result
					if host then
						ok, result = ListingsStore.kickMember(host, guid)
					else
						ok, result = ListingsStore.kickMemberByGuid(listing.hostGuid, guid)
					end
					if ok then
						player:sendTextMessage(
							MESSAGE_EVENT_ADVANCE,
							string.format("You left %s's expedition team.", listing.hostName or "the team")
						)
					end
					return ok, result
				end
			end
		end
	end
	return false, "You are not on an expedition team."
end

function ListingsStore.kickMemberByGuid(hostGuid, memberGuidOrName)
	hostGuid = tonumber(hostGuid) or 0
	local listing = listingsByHostGuid[hostGuid]
	if not listing then
		return false, "No active listing."
	end
	local memberGuid = tonumber(memberGuidOrName) or 0
	local memberName = tostring(memberGuidOrName or ""):lower()
	local out = {}
	local kicked = nil
	for _, m in ipairs(listing.members) do
		if m.guid == listing.hostGuid then
			out[#out + 1] = m
		elseif m.guid == memberGuid or m.name:lower() == memberName then
			kicked = m
			joinRequestsByJoiner[m.guid] = nil
		else
			out[#out + 1] = m
		end
	end
	if not kicked then
		return false, "Member not found."
	end
	listing.members = out
	refreshFreeSlots(listing)
	if kicked.status == SocialConfig.MEMBER_STATUS_ACCEPTED then
		local host = Player(listing.hostGuid) or Player(listing.hostName)
		local online = Player(kicked.guid) or Player(kicked.name)
		if host and online then
			excludeFromTeamChannel(host, online)
		end
	end
	saveListing(listing)
	return true, { listing = listingWire(listing), member = kicked }
end

function ListingsStore.kickMember(host, memberGuidOrName)
	if not host then
		return false, "No host."
	end
	return ListingsStore.kickMemberByGuid(host:getGuid(), memberGuidOrName)
end

function ListingsStore.getMyListingWire(player)
	local own = listingsByHostGuid[player:getGuid()]
	if own then
		return listingWire(own)
	end
	local membership = ListingsStore.findMembership(player)
	if membership and membership.listing then
		return listingWire(membership.listing)
	end
	-- Same-account host listing only when this character is on the account team roster.
	local hostPlayer = ListingsStore.findHostForAccount(player:getAccountId())
	if hostPlayer and hostPlayer:getGuid() ~= player:getGuid() then
		local onRoster = TeamStore
			and TeamStore.isOnControllerRoster
			and TeamStore.isOnControllerRoster(player, hostPlayer)
		if onRoster then
			local listing = listingsByHostGuid[hostPlayer:getGuid()]
			if listing then
				return listingWire(listing)
			end
		end
	end
	if TeamStore and TeamStore.resolveTeamController and TeamStore.reconcileControllerPointer then
		TeamStore.reconcileControllerPointer(player)
		local controller = TeamStore.resolveTeamController(player)
		if controller and controller:getGuid() ~= player:getGuid() then
			if not (TeamStore.isOnControllerRoster and TeamStore.isOnControllerRoster(player, controller)) then
				local listed = ListingsStore.playerOnHostListing and ListingsStore.playerOnHostListing(controller, player)
				if not listed then
					return nil
				end
			end
			local listing = listingsByHostGuid[controller:getGuid()]
			if listing then
				return listingWire(listing)
			end
			local raw = decodeStored(kvGet(controller, SocialConfig.KV_LISTING))
			if type(raw) == "table" and raw.hostGuid ~= nil then
				raw.hostGuid = controller:getGuid()
				raw.hostName = controller:getName()
				refreshFreeSlots(raw)
				return listingWire(raw)
			end
		end
	end
	return nil
end

function ListingsStore.getJoinInvitationsFor(player)
	-- Pending join requests where this player is host (received) or joiner (sent).
	local received = {}
	local sent = {}
	local myListing = listingsByHostGuid[player:getGuid()]
	if myListing then
		for _, m in ipairs(myListing.members or {}) do
			if m.status == SocialConfig.MEMBER_STATUS_PENDING then
				received[#received + 1] = {
					kind = "listing",
					guid = m.guid,
					name = m.name,
					level = m.level,
					vocation = m.vocation,
					hostGuid = myListing.hostGuid,
					hostName = myListing.hostName,
					expeditionName = myListing.expeditionName,
					created = myListing.created,
					direction = "received",
				}
			end
		end
	end
	local req = joinRequestsByJoiner[player:getGuid()]
	if req then
		local listing = listingsByHostGuid[req.hostGuid]
		if listing then
			sent[#sent + 1] = {
				kind = "listing",
				guid = listing.hostGuid,
				name = listing.hostName,
				hostGuid = listing.hostGuid,
				hostName = listing.hostName,
				expeditionName = listing.expeditionName,
				created = req.created,
				direction = "sent",
			}
		end
	end
	return { received = received, sent = sent }
end
