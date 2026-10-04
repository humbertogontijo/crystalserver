FriendsStore = FriendsStore or {}

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

local function normalizeGroup(group)
	group = tostring(group or ""):lower()
	if group == SocialConfig.GROUP_CLOSE or group == "close friends" or group == "closefriends" then
		return SocialConfig.GROUP_CLOSE
	end
	if group == SocialConfig.GROUP_CONTACTS or group == "contact" then
		return SocialConfig.GROUP_CONTACTS
	end
	return SocialConfig.GROUP_FRIENDS
end

local function emptyData()
	return {
		friends = {},
		incoming = {},
		outgoing = {},
		pendingAccept = {}, -- offline reverse-accepts applied on login
	}
end

local function decodeStored(stored)
	if type(stored) == "string" and stored ~= "" then
		local decoded = JsonParser.decode(stored)
		if type(decoded) == "table" then
			return decoded
		end
	elseif type(stored) == "table" then
		return stored
	end
	return nil
end

local function sanitizeData(raw)
	local data = emptyData()
	if type(raw) ~= "table" then
		return data
	end
	local seen = {}
	if type(raw.friends) == "table" then
		for _, f in ipairs(raw.friends) do
			if type(f) == "table" then
				local guid = tonumber(f.guid) or 0
				local name = tostring(f.name or ""):match("^%s*(.-)%s*$") or ""
				if guid > 0 and name ~= "" and not seen[guid] then
					seen[guid] = true
					data.friends[#data.friends + 1] = {
						guid = guid,
						name = name,
						group = normalizeGroup(f.group),
					}
				end
			end
		end
	end
	local function copyRequests(src, dest)
		if type(src) ~= "table" then
			return
		end
		local reqSeen = {}
		for _, r in ipairs(src) do
			if type(r) == "table" then
				local guid = tonumber(r.fromGuid or r.toGuid or r.guid) or 0
				local name = tostring(r.fromName or r.toName or r.name or ""):match("^%s*(.-)%s*$") or ""
				if guid > 0 and not reqSeen[guid] then
					reqSeen[guid] = true
					dest[#dest + 1] = {
						fromGuid = tonumber(r.fromGuid) or nil,
						fromName = r.fromName and tostring(r.fromName) or nil,
						toGuid = tonumber(r.toGuid) or nil,
						toName = r.toName and tostring(r.toName) or nil,
						guid = guid,
						name = name,
						created = tonumber(r.created) or os.time(),
					}
				end
			end
		end
	end
	copyRequests(raw.incoming, data.incoming)
	copyRequests(raw.outgoing, data.outgoing)
	if type(raw.pendingAccept) == "table" then
		local pSeen = {}
		for _, p in ipairs(raw.pendingAccept) do
			if type(p) == "table" then
				local guid = tonumber(p.guid) or 0
				local name = tostring(p.name or ""):match("^%s*(.-)%s*$") or ""
				if guid > 0 and name ~= "" and not pSeen[guid] then
					pSeen[guid] = true
					data.pendingAccept[#data.pendingAccept + 1] = {
						guid = guid,
						name = name,
						group = normalizeGroup(p.group),
					}
				end
			end
		end
	end
	return data
end

function FriendsStore.load(player)
	if not player then
		return emptyData()
	end
	return sanitizeData(decodeStored(kvGet(player, SocialConfig.KV_FRIENDS)))
end

function FriendsStore.save(player, data)
	if not player then
		return false
	end
	local payload = JsonParser.encode(sanitizeData(data))
	return kvSet(player, SocialConfig.KV_FRIENDS, payload)
end

local function resolveCharacter(nameOrGuid)
	if not nameOrGuid then
		return nil, "Invalid request."
	end
	local candidate = nil
	if type(nameOrGuid) == "number" then
		candidate = Player(nameOrGuid) or Game.getOfflinePlayer(nameOrGuid)
	else
		local name = tostring(nameOrGuid):match("^%s*(.-)%s*$") or ""
		if name == "" then
			return nil, "Invalid name."
		end
		candidate = Player(name) or Game.getOfflinePlayer(name)
	end
	if not candidate then
		return nil, "Character not found."
	end
	return candidate
end

local function findFriendIndex(data, guid)
	for i, f in ipairs(data.friends) do
		if f.guid == guid then
			return i
		end
	end
	return nil
end

local function removeFromList(list, guidField, guid)
	local out = {}
	for _, row in ipairs(list) do
		local g = tonumber(row[guidField] or row.guid) or 0
		if g ~= guid then
			out[#out + 1] = row
		end
	end
	return out
end

local function addFriendEntry(data, guid, name, group)
	local idx = findFriendIndex(data, guid)
	if idx then
		data.friends[idx].name = name
		if group then
			data.friends[idx].group = normalizeGroup(group)
		end
		return
	end
	local maxFriends = SocialConfig.MAX_FRIENDS or 200
	if #data.friends >= maxFriends then
		return false, "Friend list is full."
	end
	data.friends[#data.friends + 1] = {
		guid = guid,
		name = name,
		group = normalizeGroup(group),
	}
	return true
end

--- Apply any offline reverse-accepts queued while this player was offline.
function FriendsStore.applyPendingAccepts(player)
	if not player then
		return
	end
	local data = FriendsStore.load(player)
	if #data.pendingAccept == 0 then
		return
	end
	for _, p in ipairs(data.pendingAccept) do
		addFriendEntry(data, p.guid, p.name, p.group)
		data.outgoing = removeFromList(data.outgoing, "toGuid", p.guid)
		data.incoming = removeFromList(data.incoming, "fromGuid", p.guid)
	end
	data.pendingAccept = {}
	FriendsStore.save(player, data)
end

function FriendsStore.isFriend(player, nameOrGuid)
	if not player or not nameOrGuid then
		return false
	end
	local data = FriendsStore.load(player)
	local guid = 0
	local nameKey = nil
	if type(nameOrGuid) == "number" then
		guid = nameOrGuid
	else
		nameKey = tostring(nameOrGuid):lower()
		local online = Player(nameOrGuid)
		if online then
			guid = online:getGuid()
		end
	end
	for _, f in ipairs(data.friends) do
		if guid > 0 and f.guid == guid then
			return true
		end
		if nameKey and f.name:lower() == nameKey then
			return true
		end
	end
	return false
end

function FriendsStore.getFriendNames(player)
	local names = {}
	for _, f in ipairs(FriendsStore.load(player).friends) do
		names[#names + 1] = f.name
	end
	table.sort(names, function(a, b)
		return a:lower() < b:lower()
	end)
	return names
end

function FriendsStore.getFriendsWire(player)
	local out = {}
	for _, f in ipairs(FriendsStore.load(player).friends) do
		local online = Player(f.guid) or Player(f.name)
		local level = 0
		local vocation = ""
		local status = "offline"
		local outfit = nil
		if online then
			status = "online"
			level = online:getLevel() or 0
			local voc = online:getVocation()
			if voc then
				local ok, name = pcall(function()
					return voc:getName()
				end)
				if ok and type(name) == "string" then
					vocation = name
				end
			end
			if online.getOutfit then
				local ok, look = pcall(function()
					return online:getOutfit()
				end)
				if ok and type(look) == "table" then
					outfit = {
						type = look.lookType or look.type or 136,
						head = look.lookHead or look.head or 0,
						body = look.lookBody or look.body or 0,
						legs = look.lookLegs or look.legs or 0,
						feet = look.lookFeet or look.feet or 0,
						addons = look.lookAddons or look.addons or 0,
					}
				end
			end
		end
		out[#out + 1] = {
			guid = f.guid,
			name = f.name,
			group = f.group,
			level = level,
			vocation = vocation,
			status = status,
			outfit = outfit,
		}
	end
	return out
end

function FriendsStore.getInvitationsWire(player)
	local data = FriendsStore.load(player)
	local received = {}
	for _, r in ipairs(data.incoming) do
		received[#received + 1] = {
			kind = "friend",
			guid = r.fromGuid or r.guid,
			name = r.fromName or r.name,
			created = r.created,
			direction = "received",
		}
	end
	local sent = {}
	for _, r in ipairs(data.outgoing) do
		sent[#sent + 1] = {
			kind = "friend",
			guid = r.toGuid or r.guid,
			name = r.toName or r.name,
			created = r.created,
			direction = "sent",
		}
	end
	return { received = received, sent = sent }
end

function FriendsStore.requestFriend(player, targetName)
	if not player then
		return false, "No player."
	end
	local name = tostring(targetName or ""):match("^%s*(.-)%s*$") or ""
	if name == "" then
		return false, "Enter a character name."
	end
	if name:lower() == player:getName():lower() then
		return false, "You cannot add yourself."
	end

	local target, err = resolveCharacter(name)
	if not target then
		return false, err
	end

	local accountId = player:getAccountId()
	if accountId and accountId > 0 and target:getAccountId() == accountId then
		return false, "Same-account characters are alts, not friends."
	end

	local targetGuid = target:getGuid()
	local targetNameResolved = target:getName()
	if FriendsStore.isFriend(player, targetGuid) then
		return false, "Already friends."
	end

	local data = FriendsStore.load(player)
	for _, r in ipairs(data.outgoing) do
		if (r.toGuid or r.guid) == targetGuid then
			return false, "Friend request already sent."
		end
	end
	-- If they already requested us, accept instead.
	for _, r in ipairs(data.incoming) do
		if (r.fromGuid or r.guid) == targetGuid then
			return FriendsStore.acceptFriend(player, targetGuid)
		end
	end

	data.outgoing[#data.outgoing + 1] = {
		toGuid = targetGuid,
		toName = targetNameResolved,
		guid = targetGuid,
		name = targetNameResolved,
		created = os.time(),
	}
	FriendsStore.save(player, data)

	-- Mirror incoming on target (online or offline KV).
	local targetData = FriendsStore.load(target)
	local already = false
	for _, r in ipairs(targetData.incoming) do
		if (r.fromGuid or r.guid) == player:getGuid() then
			already = true
			break
		end
	end
	if not already then
		targetData.incoming[#targetData.incoming + 1] = {
			fromGuid = player:getGuid(),
			fromName = player:getName(),
			guid = player:getGuid(),
			name = player:getName(),
			created = os.time(),
		}
		FriendsStore.save(target, targetData)
	end

	local onlineTarget = Player(targetGuid) or Player(targetNameResolved)
	return true, {
		targetGuid = targetGuid,
		targetName = targetNameResolved,
		online = onlineTarget ~= nil,
	}
end

function FriendsStore.acceptFriend(player, fromGuidOrName)
	if not player then
		return false, "No player."
	end
	local fromGuid = tonumber(fromGuidOrName) or 0
	local fromName = nil
	if fromGuid == 0 then
		local other = resolveCharacter(fromGuidOrName)
		if not other then
			return false, "Request not found."
		end
		fromGuid = other:getGuid()
		fromName = other:getName()
	end

	local data = FriendsStore.load(player)
	local found = nil
	for _, r in ipairs(data.incoming) do
		if (r.fromGuid or r.guid) == fromGuid then
			found = r
			break
		end
	end
	if not found then
		return false, "No pending friend request."
	end
	fromName = found.fromName or found.name or fromName or ("#" .. tostring(fromGuid))

	local ok, err = addFriendEntry(data, fromGuid, fromName, SocialConfig.GROUP_FRIENDS)
	if ok == false then
		return false, err
	end
	data.incoming = removeFromList(data.incoming, "fromGuid", fromGuid)
	data.outgoing = removeFromList(data.outgoing, "toGuid", fromGuid)
	FriendsStore.save(player, data)

	-- Reverse side: online player or offline KV pendingAccept.
	local other = Player(fromGuid) or Player(fromName)
	if other then
		local otherData = FriendsStore.load(other)
		addFriendEntry(otherData, player:getGuid(), player:getName(), SocialConfig.GROUP_FRIENDS)
		otherData.outgoing = removeFromList(otherData.outgoing, "toGuid", player:getGuid())
		otherData.incoming = removeFromList(otherData.incoming, "fromGuid", player:getGuid())
		FriendsStore.save(other, otherData)
	else
		local offline = Game.getOfflinePlayer(fromGuid) or Game.getOfflinePlayer(fromName)
		if offline then
			local otherData = FriendsStore.load(offline)
			otherData.pendingAccept = otherData.pendingAccept or {}
			local exists = false
			for _, p in ipairs(otherData.pendingAccept) do
				if p.guid == player:getGuid() then
					exists = true
					break
				end
			end
			if not exists then
				otherData.pendingAccept[#otherData.pendingAccept + 1] = {
					guid = player:getGuid(),
					name = player:getName(),
					group = SocialConfig.GROUP_FRIENDS,
				}
			end
			otherData.outgoing = removeFromList(otherData.outgoing, "toGuid", player:getGuid())
			FriendsStore.save(offline, otherData)
		end
	end

	return true, { guid = fromGuid, name = fromName }
end

function FriendsStore.declineFriend(player, fromGuidOrName)
	if not player then
		return false, "No player."
	end
	local fromGuid = tonumber(fromGuidOrName) or 0
	local fromName = nil
	if fromGuid == 0 then
		fromName = tostring(fromGuidOrName or "")
		local other = resolveCharacter(fromGuidOrName)
		if other then
			fromGuid = other:getGuid()
			fromName = other:getName()
		end
	end
	if fromGuid == 0 then
		return false, "Request not found."
	end

	local data = FriendsStore.load(player)
	data.incoming = removeFromList(data.incoming, "fromGuid", fromGuid)
	FriendsStore.save(player, data)

	local other = Player(fromGuid) or (fromName and Player(fromName)) or Game.getOfflinePlayer(fromGuid)
	if other then
		local otherData = FriendsStore.load(other)
		otherData.outgoing = removeFromList(otherData.outgoing, "toGuid", player:getGuid())
		FriendsStore.save(other, otherData)
	end
	return true
end

function FriendsStore.removeFriend(player, nameOrGuid)
	if not player then
		return false, "No player."
	end
	local data = FriendsStore.load(player)
	local guid = tonumber(nameOrGuid) or 0
	local name = nil
	if guid == 0 then
		name = tostring(nameOrGuid or ""):lower()
		for _, f in ipairs(data.friends) do
			if f.name:lower() == name then
				guid = f.guid
				name = f.name
				break
			end
		end
	else
		for _, f in ipairs(data.friends) do
			if f.guid == guid then
				name = f.name
				break
			end
		end
	end
	if guid == 0 then
		return false, "Friend not found."
	end

	local out = {}
	for _, f in ipairs(data.friends) do
		if f.guid ~= guid then
			out[#out + 1] = f
		end
	end
	data.friends = out
	FriendsStore.save(player, data)

	-- Best-effort remove reverse friendship.
	local other = Player(guid) or (name and Player(name)) or Game.getOfflinePlayer(guid)
	if other then
		local otherData = FriendsStore.load(other)
		local cleaned = {}
		for _, f in ipairs(otherData.friends) do
			if f.guid ~= player:getGuid() then
				cleaned[#cleaned + 1] = f
			end
		end
		otherData.friends = cleaned
		FriendsStore.save(other, otherData)
	end
	return true, { guid = guid, name = name }
end

function FriendsStore.setFriendGroup(player, nameOrGuid, group)
	if not player then
		return false, "No player."
	end
	local data = FriendsStore.load(player)
	local guid = tonumber(nameOrGuid) or 0
	local nameKey = tostring(nameOrGuid or ""):lower()
	local found = false
	for _, f in ipairs(data.friends) do
		if (guid > 0 and f.guid == guid) or f.name:lower() == nameKey then
			f.group = normalizeGroup(group)
			found = true
			break
		end
	end
	if not found then
		return false, "Friend not found."
	end
	FriendsStore.save(player, data)
	return true
end

local function vocationNameFromId(vocId)
	vocId = tonumber(vocId) or 0
	if vocId <= 0 or not Vocation then
		return ""
	end
	local ok, voc = pcall(function()
		return Vocation(vocId)
	end)
	if not ok or not voc then
		return ""
	end
	local okName, name = pcall(function()
		return voc:getName()
	end)
	if okName and type(name) == "string" then
		return name
	end
	return ""
end

local function worldName()
	if SERVER_NAME and SERVER_NAME ~= "" then
		return tostring(SERVER_NAME)
	end
	if configManager and configKeys and configKeys.SERVER_NAME then
		local ok, name = pcall(function()
			return configManager.getString(configKeys.SERVER_NAME)
		end)
		if ok and type(name) == "string" and name ~= "" then
			return name
		end
	end
	return "World"
end

local function formatLoginDate(ts)
	ts = tonumber(ts) or 0
	if ts <= 0 then
		return "-"
	end
	return os.date("%Y-%m-%d", ts)
end

--- Account + character list for Social / Friends search tab.
--- Resolves by DB name first (offline-safe); does not require Game.getOfflinePlayer.
function FriendsStore.searchAccount(player, targetName)
	if not player then
		return false, "No player."
	end
	local name = tostring(targetName or ""):match("^%s*(.-)%s*$") or ""
	if name == "" then
		return false, "Enter a character name."
	end

	local accountId = 0
	-- Prefer an online player (exact name), else look up account via players table.
	local onlineTarget = Player(name)
	if onlineTarget and onlineTarget.getAccountId then
		accountId = tonumber(onlineTarget:getAccountId()) or 0
	end
	if accountId == 0 then
		local findId = db.storeQuery(
			"SELECT `account_id` FROM `players` WHERE `name` = "
				.. db.escapeString(name)
				.. " AND `deletion` = 0 LIMIT 1"
		)
		if findId then
			accountId = tonumber(Result.getNumber(findId, "account_id")) or 0
			Result.free(findId)
		end
	end
	if accountId == 0 then
		return false, "Character not found."
	end

	local onlineAny = false
	local lastLogin = 0
	local premium = false
	local title = ""
	local characters = {}

	local resultId = db.storeQuery(
		"SELECT `id`, `name`, `level`, `vocation`, `looktype`, `lookhead`, `lookbody`, `looklegs`, `lookfeet`, `lookaddons`, `lastlogin`"
			.. " FROM `players` WHERE `account_id` = "
			.. tonumber(accountId)
			.. " AND `deletion` = 0 ORDER BY `level` DESC, `name` ASC"
	)
	if resultId then
		repeat
			local guid = Result.getNumber(resultId, "id")
			local charName = Result.getString(resultId, "name")
			local level = Result.getNumber(resultId, "level")
			local vocId = Result.getNumber(resultId, "vocation")
			local login = Result.getNumber(resultId, "lastlogin") or 0
			if login > lastLogin then
				lastLogin = login
			end
			local online = Player(guid) or Player(charName)
			local creatureId = 0
			if online then
				onlineAny = true
				creatureId = tonumber(online:getId()) or 0
				if title == "" and online.getTitle and type(online.getTitle) == "function" then
					local ok, t = pcall(function()
						return online:getTitle()
					end)
					if ok and type(t) == "string" then
						title = t
					end
				end
			end
			characters[#characters + 1] = {
				guid = tonumber(guid) or 0,
				creatureId = creatureId,
				name = charName,
				level = level or 0,
				vocation = vocationNameFromId(vocId),
				world = worldName(),
				online = online ~= nil,
				outfit = {
					type = Result.getNumber(resultId, "looktype") or 136,
					head = Result.getNumber(resultId, "lookhead") or 0,
					body = Result.getNumber(resultId, "lookbody") or 0,
					legs = Result.getNumber(resultId, "looklegs") or 0,
					feet = Result.getNumber(resultId, "lookfeet") or 0,
					addons = Result.getNumber(resultId, "lookaddons") or 0,
				},
			}
		until not Result.next(resultId)
		Result.free(resultId)
	end

	if #characters == 0 then
		return false, "Character not found."
	end

	local premResult = db.storeQuery("SELECT `premdays`, `lastday` FROM `accounts` WHERE `id` = " .. tonumber(accountId))
	if premResult then
		local premDays = Result.getNumber(premResult, "premdays") or 0
		local lastDay = Result.getNumber(premResult, "lastday") or 0
		Result.free(premResult)
		if premDays > 0 or (lastDay > 0 and lastDay > os.time()) then
			premium = true
		end
	end

	return true, {
		query = name,
		accountId = accountId,
		online = onlineAny,
		lastLogin = lastLogin,
		lastLoginText = formatLoginDate(lastLogin),
		premium = premium,
		title = title,
		world = worldName(),
		characters = characters,
	}
end
