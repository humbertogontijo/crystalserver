TeamStore = TeamStore or {}

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

local function kvRemove(player, key)
	local kv = player and player:kv()
	if not kv then
		return false
	end
	kv:remove(key)
	return true
end

--- Online player by GUID. Player(guid) is unreliable on some builds; scan live players.
function TeamStore.findOnlinePlayerByGuid(guid)
	guid = tonumber(guid) or 0
	if guid <= 0 then
		return nil
	end
	local direct = Player(guid)
	if direct and direct.getGuid and direct:getGuid() == guid then
		return direct
	end
	for _, online in ipairs(Game.getPlayers()) do
		if online:getGuid() == guid then
			return online
		end
	end
	return nil
end

--- True when guid has a live ProtocolGame UI (not headless / protocol 0 / companion).
local function isRealOnlineClient(guid)
	guid = tonumber(guid) or 0
	if guid <= 0 then
		return false
	end
	local online = TeamStore.findOnlinePlayerByGuid(guid)
	if not online then
		return false
	end
	if TeamManager and TeamManager.isRealUiClient then
		return TeamManager.isRealUiClient(online) == true
	end
	if online.isHeadless and online:isHeadless() then
		return false
	end
	if TeamManager and TeamManager.isCompanion and TeamManager.isCompanion(online) then
		return false
	end
	if online.getProtocolVersion and online:getProtocolVersion() == 0 then
		return false
	end
	return true
end

function TeamStore.isRealOnlineClient(guid)
	return isRealOnlineClient(guid)
end

local function normalizeKind(kind, defaultKind)
	kind = tostring(kind or ""):lower()
	if kind == TeamConfig.KIND_FRIEND or kind == "guest" then
		return TeamConfig.KIND_FRIEND
	end
	if kind == TeamConfig.KIND_COMPANION or kind == "self" or kind == "primary" or kind == "alt" then
		return TeamConfig.KIND_COMPANION
	end
	return defaultKind or TeamConfig.KIND_COMPANION
end

local function parseMemberEntry(raw, defaultKind)
	if type(raw) == "table" then
		local name = raw.name or raw.character or raw.characterName
		name = tostring(name or ""):match("^%s*(.-)%s*$") or ""
		if name == "" then
			return nil
		end
		return {
			name = name,
			kind = normalizeKind(raw.kind or raw.type, defaultKind),
		}
	end
	local name = tostring(raw or ""):match("^%s*(.-)%s*$") or ""
	if name == "" then
		return nil
	end
	return {
		name = name,
		kind = defaultKind or TeamConfig.KIND_COMPANION,
	}
end

--- Normalize ordered members (primary forced first as companion, unique, max N).
function TeamStore.sanitizeMembers(primaryPlayer, members)
	if not primaryPlayer then
		return {}
	end
	local primaryName = primaryPlayer:getName()
	local seen = {}
	local out = {
		{
			name = primaryName,
			kind = TeamConfig.KIND_COMPANION,
		},
	}
	seen[primaryName:lower()] = true

	if type(members) ~= "table" then
		return out
	end

	local maxMembers = TeamConfig.MAX_MEMBERS or 4
	for _, raw in ipairs(members) do
		if #out >= maxMembers then
			break
		end
		local entry = parseMemberEntry(raw, TeamConfig.KIND_COMPANION)
		if entry then
			local key = entry.name:lower()
			if not seen[key] then
				seen[key] = true
				-- Primary name always companion/self even if client mis-labels.
				if key == primaryName:lower() then
					entry.kind = TeamConfig.KIND_COMPANION
				end
				out[#out + 1] = entry
			end
		end
	end
	return out
end

--- Backward-compatible name-only list (companions + friends names in order).
function TeamStore.sanitizeNames(primaryPlayer, names)
	local members = TeamStore.sanitizeMembers(primaryPlayer, names)
	local out = {}
	for _, m in ipairs(members) do
		out[#out + 1] = m.name
	end
	return out
end

local function decodeStored(stored)
	if type(stored) == "string" and stored ~= "" then
		local decoded = TeamJson.decode(stored)
		if type(decoded) == "table" then
			return decoded
		end
	elseif type(stored) == "table" then
		return stored
	end
	return nil
end

--- Who owns the account team KV for this viewer (host, same-account host, or listing host).
function TeamStore.resolvePlayerByGuid(guid)
	guid = tonumber(guid) or 0
	if guid <= 0 then
		return nil
	end
	return TeamStore.findOnlinePlayerByGuid(guid) or (Game.getOfflinePlayer and Game.getOfflinePlayer(guid))
end

function TeamStore.getControllerPointer(player)
	if not player then
		return nil
	end
	local guid = tonumber(kvGet(player, TeamConfig.KV_CONTROLLER_GUID))
	if not guid or guid <= 0 then
		return nil
	end
	return guid
end

function TeamStore.setControllerPointer(playerOrGuid, hostGuid)
	local player = playerOrGuid
	if type(playerOrGuid) == "number" then
		player = TeamStore.resolvePlayerByGuid(playerOrGuid)
	end
	if not player or not player.kv then
		return
	end
	local kv = player:kv()
	hostGuid = tonumber(hostGuid) or 0
	if hostGuid > 0 then
		kv:set(TeamConfig.KV_CONTROLLER_GUID, hostGuid)
	else
		kv:remove(TeamConfig.KV_CONTROLLER_GUID)
	end
end

local function companionMembersForHost(host, members)
	local hostGuid = host:getGuid()
	local out = {}
	for i = 2, #(members or {}) do
		local entry = members[i]
		if entry and entry.kind ~= TeamConfig.KIND_FRIEND then
			local member, err = TeamStore.resolveAccountMember(host, entry.name)
			if member and member:getGuid() ~= hostGuid then
				out[member:getGuid()] = member
			elseif not member and err then
				-- ignore unresolved names during sync
			end
		end
	end
	return out
end

function TeamStore.syncControllerPointers(host, newMembers, oldMembers)
	if not host then
		return
	end
	local hostGuid = host:getGuid()
	local newMap = companionMembersForHost(host, newMembers)
	local oldMap = companionMembersForHost(host, oldMembers)
	for _, member in pairs(newMap) do
		TeamStore.setControllerPointer(member, hostGuid)
	end
	for guid, member in pairs(oldMap) do
		if not newMap[guid] then
			TeamStore.setControllerPointer(member, nil)
		end
	end
end

--- True when player is a same-account companion entry on controller's roster (not friends).
function TeamStore.isOnControllerRoster(player, controller)
	if not player or not controller then
		return false
	end
	if player:getGuid() == controller:getGuid() then
		return true
	end
	local accountId = player:getAccountId()
	if not accountId or accountId <= 0 or controller:getAccountId() ~= accountId then
		return false
	end
	local raw = decodeStored(kvGet(controller, TeamConfig.KV_MEMBERS))
	if not raw then
		raw = decodeStored(kvGet(controller, TeamConfig.KV_MEMBERS_LEGACY))
	end
	if type(raw) ~= "table" then
		return false
	end
	local myName = player:getName():lower()
	for _, entry in ipairs(TeamStore.sanitizeMembers(controller, raw)) do
		if entry.name and entry.name:lower() == myName and entry.kind ~= TeamConfig.KIND_FRIEND then
			return true
		end
	end
	return false
end

--- One-time / login repair when roster was saved before controller pointers existed.
--- Also clears stale pointers when this character is no longer on the host roster.
function TeamStore.reconcileControllerPointer(player)
	if not player then
		return
	end
	local existing = TeamStore.getControllerPointer(player)
	if existing and existing ~= player:getGuid() then
		local host = TeamStore.resolvePlayerByGuid(existing)
		if host and TeamStore.isOnControllerRoster(player, host) then
			return
		end
		-- Stale pointer (removed from roster, wrong host, or host wiped) — drop it.
		TeamStore.setControllerPointer(player, nil)
		existing = nil
	end
	if existing then
		return
	end
	if ListingsStore and ListingsStore.getByHost and ListingsStore.getByHost(player) then
		return
	end
	local accountId = player:getAccountId()
	if not accountId or accountId <= 0 then
		return
	end
	local myGuid = player:getGuid()
	local myName = player:getName():lower()
	local resultId = db.storeQuery(
		"SELECT `id` FROM `players` WHERE `account_id` = "
			.. tonumber(accountId)
			.. " AND `deletion` = 0"
	)
	if not resultId then
		return
	end
	repeat
		local guid = Result.getNumber(resultId, "id")
		if guid and guid ~= myGuid then
			local host = TeamStore.resolvePlayerByGuid(guid)
			if host then
				local raw = decodeStored(kvGet(host, TeamConfig.KV_MEMBERS))
				if type(raw) == "table" and #raw > 1 then
					for _, entry in ipairs(TeamStore.sanitizeMembers(host, raw)) do
						if entry.name and entry.name:lower() == myName and entry.kind ~= TeamConfig.KIND_FRIEND then
							TeamStore.setControllerPointer(player, host:getGuid())
							Result.free(resultId)
							return
						end
					end
				end
			end
		end
	until not Result.next(resultId)
	Result.free(resultId)
end

--- When the roster controller is offline, same-account roster member becomes host.
--- opts.force: transfer even if fromHostGuid is still in Game.getPlayers (host logout handoff).
--- opts.fromHostGuid: preferred host to adopt from (logout handoff).
function TeamStore.adoptAccountTeamLeadership(player, opts)
	opts = opts or {}
	if not player then
		return false
	end
	TeamStore.reconcileControllerPointer(player)

	local pointerGuid = TeamStore.getControllerPointer(player)
	local fromHostGuid = tonumber(opts.fromHostGuid) or 0
	if fromHostGuid > 0 and (not pointerGuid or pointerGuid == player:getGuid()) then
		TeamStore.setControllerPointer(player, fromHostGuid)
		pointerGuid = fromHostGuid
	end

	-- Discover offline account host via roster if pointer is missing.
	if not pointerGuid or pointerGuid == player:getGuid() then
		local accountId = player:getAccountId()
		if accountId and accountId > 0 then
			local myGuid = player:getGuid()
			local resultId = db.storeQuery(
				"SELECT `id` FROM `players` WHERE `account_id` = "
					.. tonumber(accountId)
					.. " AND `deletion` = 0"
			)
			if resultId then
				repeat
					local guid = Result.getNumber(resultId, "id")
					if guid and guid ~= myGuid then
						local host = TeamStore.resolvePlayerByGuid(guid)
						if host and TeamStore.isOnControllerRoster(player, host) then
							local raw = decodeStored(kvGet(host, TeamConfig.KV_MEMBERS))
							if not raw then
								raw = decodeStored(kvGet(host, TeamConfig.KV_MEMBERS_LEGACY))
							end
							if type(raw) == "table" and #raw > 1 then
								TeamStore.setControllerPointer(player, host:getGuid())
								pointerGuid = host:getGuid()
								break
							end
						end
					end
				until not Result.next(resultId)
				Result.free(resultId)
			end
		end
	end

	-- Same-account parked/live listing membership without roster pointer yet.
	if (not pointerGuid or pointerGuid == player:getGuid()) and ListingsStore and ListingsStore.findParkedAccountHostForMember then
		local parkedHost = ListingsStore.findParkedAccountHostForMember(player)
		if parkedHost then
			TeamStore.setControllerPointer(player, parkedHost:getGuid())
			pointerGuid = parkedHost:getGuid()
		end
	end

	pointerGuid = TeamStore.getControllerPointer(player)
	if not pointerGuid or pointerGuid == player:getGuid() then
		return false
	end

	local oldHost = TeamStore.resolvePlayerByGuid(pointerGuid)
	if not oldHost then
		return false
	end

	local accountId = player:getAccountId()
	if not accountId or accountId <= 0 or oldHost:getAccountId() ~= accountId then
		return false
	end

	if not opts.force and isRealOnlineClient(pointerGuid) then
		return false
	end

	local raw = decodeStored(kvGet(oldHost, TeamConfig.KV_MEMBERS))
	if not raw then
		raw = decodeStored(kvGet(oldHost, TeamConfig.KV_MEMBERS_LEGACY))
	end
	local members = TeamStore.sanitizeMembers(oldHost, raw or {})

	-- Heal: ensure adopting player is on the member list (listing-only same-account joins).
	local myName = player:getName():lower()
	local onRoster = false
	for _, entry in ipairs(members) do
		if entry.name and entry.name:lower() == myName and entry.kind ~= TeamConfig.KIND_FRIEND then
			onRoster = true
			break
		end
	end
	if not onRoster then
		local listed = ListingsStore and ListingsStore.playerOnHostListing and ListingsStore.playerOnHostListing(oldHost, player)
		if not listed and not opts.force then
			return false
		end
		members[#members + 1] = { name = player:getName(), kind = TeamConfig.KIND_COMPANION }
		members = TeamStore.sanitizeMembers(oldHost, members)
	end

	if #members <= 1 then
		return false
	end

	local ok = TeamStore.setMembersOnController(player, members)
	if not ok then
		return false
	end

	-- Team prey / XP boost are team-scoped: move with the roster controller.
	local bonuses = kvGet(oldHost, TeamConfig.KV_BONUSES)
	if bonuses ~= nil then
		kvSet(player, TeamConfig.KV_BONUSES, bonuses)
		kvRemove(oldHost, TeamConfig.KV_BONUSES)
	end

	kvRemove(oldHost, TeamConfig.KV_MEMBERS)
	kvRemove(oldHost, TeamConfig.KV_MEMBERS_LEGACY)
	TeamStore.setControllerPointer(oldHost, player:getGuid())
	TeamStore.setControllerPointer(player, nil)

	if TeamManager and TeamManager.retargetRosterInvites then
		TeamManager.retargetRosterInvites(pointerGuid, player:getGuid(), player:getName())
	end
	if ListingsStore and ListingsStore.adoptListing then
		ListingsStore.adoptListing(player, oldHost)
	end
	if TeamBonus and TeamBonus.syncCombatCache then
		pcall(TeamBonus.syncCombatCache, player)
	end

	return true
end

function TeamStore.resolveTeamController(player)
	if not player then
		return nil
	end
	local pointerGuid = TeamStore.getControllerPointer(player)
	if ListingsStore and ListingsStore.getByHost and ListingsStore.getByHost(player) then
		if pointerGuid and pointerGuid ~= player:getGuid() then
			local host = TeamStore.resolvePlayerByGuid(pointerGuid)
			if host and TeamStore.isOnControllerRoster(player, host) then
				return host
			end
		end
		return player
	end
	if pointerGuid and pointerGuid ~= player:getGuid() then
		local host = TeamStore.resolvePlayerByGuid(pointerGuid)
		if host and TeamStore.isOnControllerRoster(player, host) then
			return host
		end
		-- Pointer without roster membership is stale; ignore it.
		TeamStore.setControllerPointer(player, nil)
	end
	if ListingsStore and ListingsStore.findMembership then
		local membership = ListingsStore.findMembership(player)
		if membership and membership.hostGuid then
			local host = TeamStore.findOnlinePlayerByGuid(membership.hostGuid)
			if not host and Game.getOfflinePlayer then
				host = Game.getOfflinePlayer(membership.hostGuid)
			end
			if host then
				return host
			end
		end
	end
	-- Same-account listing host only when this character is on that host's roster.
	local accountId = player:getAccountId()
	if accountId and accountId > 0 and ListingsStore and ListingsStore.findHostForAccount then
		local hostPlayer = ListingsStore.findHostForAccount(accountId)
		if hostPlayer and hostPlayer:getGuid() ~= player:getGuid() then
			if TeamStore.isOnControllerRoster(player, hostPlayer) then
				return hostPlayer
			end
		end
	end
	return player
end

function TeamStore.canEditTeam(player)
	if not player then
		return false
	end
	local controller = TeamStore.resolveTeamController(player)
	return controller ~= nil and controller:getGuid() == player:getGuid()
end

function TeamStore.setMembersOnController(controller, members)
	if not controller then
		return false, "No player."
	end
	local oldRaw = decodeStored(kvGet(controller, TeamConfig.KV_MEMBERS))
	local oldSanitized = TeamStore.sanitizeMembers(controller, oldRaw or {})
	local sanitized = TeamStore.sanitizeMembers(controller, members)
	local payload = TeamJson.encode(sanitized)
	if not kvSet(controller, TeamConfig.KV_MEMBERS, payload) then
		return false, "Failed to persist team."
	end
	TeamStore.syncControllerPointers(controller, sanitized, oldSanitized)
	return true, sanitized
end

function TeamStore.getMembers(player)
	if not player then
		return {}
	end
	local controller = TeamStore.resolveTeamController(player)
	if not controller then
		controller = player
	end
	local stored = kvGet(controller, TeamConfig.KV_MEMBERS)
	local raw = decodeStored(stored)
	local migrated = false
	if not raw then
		local legacy = kvGet(controller, TeamConfig.KV_MEMBERS_LEGACY)
		raw = decodeStored(legacy)
		if raw then
			migrated = true
		end
	end
	local members = TeamStore.sanitizeMembers(controller, raw or {})
	if migrated then
		TeamStore.setMembersOnController(controller, members)
		kvRemove(controller, TeamConfig.KV_MEMBERS_LEGACY)
	end
	return members
end

function TeamStore.getMemberNames(player)
	local members = TeamStore.getMembers(player)
	local names = {}
	for _, m in ipairs(members) do
		names[#names + 1] = m.name
	end
	return names
end

function TeamStore.setMembers(player, members)
	if not player then
		return false, "No player."
	end
	if not TeamStore.canEditTeam(player) then
		return false, "Only the team host can edit the roster."
	end
	return TeamStore.setMembersOnController(player, members)
end

function TeamStore.setMemberNames(player, names)
	-- Legacy API: treat bare names as companions.
	return TeamStore.setMembers(player, names)
end

function TeamStore.resolveCharacter(nameOrGuid)
	if not nameOrGuid then
		return nil, "Invalid request."
	end
	local candidate = nil
	if type(nameOrGuid) == "number" then
		candidate = Player(nameOrGuid) or Game.getOfflinePlayer(nameOrGuid)
	else
		local name = tostring(nameOrGuid)
		candidate = Player(name) or Game.getOfflinePlayer(name)
	end
	if not candidate then
		return nil, "Character not found."
	end
	return candidate
end

function TeamStore.resolveAccountMember(controller, nameOrGuid)
	if not controller then
		return nil, "Invalid request."
	end
	local accountId = controller:getAccountId()
	if not accountId or accountId == 0 then
		return nil, "No account."
	end

	local candidate, err = TeamStore.resolveCharacter(nameOrGuid)
	if not candidate then
		return nil, err
	end
	if candidate:getAccountId() ~= accountId then
		return nil, "Character is not on your account."
	end
	return candidate
end

--- True when target guid/name is on controller's product friends list.
function TeamStore.isFriend(controller, nameOrGuid)
	if not controller or not nameOrGuid then
		return false
	end
	if FriendsStore and FriendsStore.isFriend then
		return FriendsStore.isFriend(controller, nameOrGuid) == true
	end
	return false
end

function TeamStore.resolveFriendMember(controller, nameOrGuid)
	local candidate, err = TeamStore.resolveCharacter(nameOrGuid)
	if not candidate then
		return nil, err
	end
	local accountId = controller:getAccountId()
	if accountId and accountId > 0 and candidate:getAccountId() == accountId then
		return nil, "Use companion for same-account characters."
	end
	if not TeamStore.isFriend(controller, candidate:getGuid()) and not TeamStore.isFriend(controller, candidate:getName()) then
		return nil, "Only friends can join your team."
	end
	return candidate
end

function TeamStore.getCompanionNames(player)
	local names = {}
	for _, m in ipairs(TeamStore.getMembers(player)) do
		if m.kind ~= TeamConfig.KIND_FRIEND then
			names[#names + 1] = m.name
		end
	end
	return names
end

function TeamStore.getFriendNames(player)
	local names = {}
	for _, m in ipairs(TeamStore.getMembers(player)) do
		if m.kind == TeamConfig.KIND_FRIEND then
			names[#names + 1] = m.name
		end
	end
	return names
end
