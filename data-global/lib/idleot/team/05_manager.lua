TeamManager = TeamManager or {}

-- primaryGuid → { companionIds = {playerId, ...}, partyOwned = bool }
local deployments = {}
-- friendGuid → { hostGuid, hostName, expires }
local rosterInvitesByFriendGuid = {}

function TeamManager.retargetRosterInvites(oldHostGuid, newHostGuid, newHostName)
	oldHostGuid = tonumber(oldHostGuid) or 0
	newHostGuid = tonumber(newHostGuid) or 0
	if oldHostGuid <= 0 or newHostGuid <= 0 or oldHostGuid == newHostGuid then
		return
	end
	for _, invite in pairs(rosterInvitesByFriendGuid) do
		if invite and invite.hostGuid == oldHostGuid then
			invite.hostGuid = newHostGuid
			if newHostName and newHostName ~= "" then
				invite.hostName = newHostName
			end
		end
	end
end

--- Outfit table for manage-team portraits (online or offline Player).
local function outfitFromSource(src)
	if not src or not src.getOutfit then
		return nil
	end
	local ok, look = pcall(function()
		return src:getOutfit()
	end)
	if not ok or type(look) ~= "table" then
		return nil
	end
	local lookType = tonumber(look.lookType or look.type) or 0
	if lookType <= 0 then
		return nil
	end
	return {
		type = lookType,
		head = tonumber(look.lookHead or look.head) or 0,
		body = tonumber(look.lookBody or look.body) or 0,
		legs = tonumber(look.lookLegs or look.legs) or 0,
		feet = tonumber(look.lookFeet or look.feet) or 0,
		addons = tonumber(look.lookAddons or look.addons) or 0,
	}
end

--- Level + vocation + outfit for manage-team slots / automation catalogs.
local function memberProfileWire(src)
	if not src then
		return { level = 0, vocation = "", outfit = nil }
	end
	local vocationName = ""
	local vocation = src.getVocation and src:getVocation() or nil
	if vocation then
		local ok, name = pcall(function()
			return vocation:getName()
		end)
		if ok and type(name) == "string" then
			vocationName = name
		end
	end
	return {
		level = src.getLevel and src:getLevel() or 0,
		vocation = vocationName,
		outfit = outfitFromSource(src),
	}
end

-- Inventory locations must use equip-slot paths, not Lua ScriptEnv unique ids.
-- Item:getUniqueId() assigns ephemeral script-env thing ids that change per packet
-- and cannot be looked up later (causes "Container not found.").
local function copyPath(path)
	if type(path) ~= "table" then
		return nil
	end
	if path.rewardChest == true then
		local out = { rewardChest = true }
		if path.rewardId ~= nil then
			out.rewardId = tonumber(path.rewardId) or path.rewardId
		end
		if type(path.indices) == "table" then
			out.indices = {}
			for i, idx in ipairs(path.indices) do
				out.indices[i] = tonumber(idx) or 0
			end
		end
		return out
	end
	if path.lootPouch == true then
		local out = { lootPouch = true }
		if type(path.indices) == "table" then
			out.indices = {}
			for i, idx in ipairs(path.indices) do
				out.indices[i] = tonumber(idx) or 0
			end
		end
		return out
	end
	local out = { slot = tonumber(path.slot) or 0 }
	if type(path.indices) == "table" then
		out.indices = {}
		for i, idx in ipairs(path.indices) do
			out.indices[i] = tonumber(idx) or 0
		end
	end
	return out
end

local function childPath(parentPath, index)
	local path = copyPath(parentPath) or { slot = 0, indices = {} }
	path.indices = path.indices or {}
	path.indices[#path.indices + 1] = tonumber(index) or 0
	return path
end

local function itemWire(item, path)
	if not item then
		return nil
	end
	local count = 1
	local ok, raw = pcall(function()
		return item:getCount()
	end)
	if ok and raw ~= nil then
		local n = tonumber(raw)
		if n and n >= 1 then
			count = math.floor(n)
		end
	end
	-- Stackables / charges that report via subtype-style getters.
	if count <= 1 then
		ok, raw = pcall(function()
			if item.getCharges then
				return item:getCharges()
			end
			return nil
		end)
		if ok and raw ~= nil then
			local n = tonumber(raw)
			if n and n > 1 then
				count = math.floor(n)
			end
		end
	end
	local name = item:getName() or "?"
	local itemId = item:getId() or 0
	local isContainer = false
	if item.isContainer then
		isContainer = item:isContainer() == true
	end
	return {
		path = copyPath(path),
		itemId = itemId,
		name = name,
		count = count,
		isContainer = isContainer == true,
	}
end

local function containerWire(container, parentPath, maxItems)
	maxItems = maxItems or 40
	local items = {}
	if not container or not container.getSize then
		return items
	end
	local size = container:getSize() or 0
	for i = 0, size - 1 do
		if #items >= maxItems then
			break
		end
		local it = container:getItem(i)
		if it then
			items[#items + 1] = itemWire(it, childPath(parentPath, i))
		end
	end
	return items
end

local LOOT_POUCH_ID = ITEM_GOLD_POUCH or 23721

--- Find loot pouch + equip-path (store inbox index preferred).
local function findLootPouch(player)
	if not player then
		return nil, nil
	end
	local inboxSlot = CONST_SLOT_STORE_INBOX or 11
	local inbox = player.getStoreInbox and player:getStoreInbox() or player:getSlotItem(inboxSlot)
	if inbox and inbox.getSize then
		local size = inbox:getSize() or 0
		for i = 0, size - 1 do
			local it = inbox:getItem(i)
			if it and it:getId() == LOOT_POUCH_ID then
				return it, { slot = inboxSlot, indices = { i } }
			end
		end
	end
	if player.findItemInInbox then
		local pouch = player:findItemInInbox(LOOT_POUCH_ID)
		if pouch then
			return pouch, { lootPouch = true }
		end
	end
	if player.getItemById then
		local pouch = player:getItemById(LOOT_POUCH_ID, true)
		if pouch then
			return pouch, { lootPouch = true }
		end
	end
	return nil, nil
end

--- Resolve inventory item by equip slot + nested container indices.
local function resolveItemByPath(player, path)
	if not player or type(path) ~= "table" then
		return nil
	end
	if path.rewardChest == true then
		local rewardId = path.rewardId
		if rewardId == nil then
			return nil
		end
		if not player.getReward then
			return nil
		end
		local reward = player:getReward(rewardId, false)
		if not reward or reward == false then
			return nil
		end
		local indices = path.indices
		if type(indices) ~= "table" or #indices == 0 then
			return reward
		end
		local item = reward
		for _, rawIndex in ipairs(indices) do
			local index = tonumber(rawIndex)
			if index == nil or not item.getSize then
				return nil
			end
			local size = item:getSize() or 0
			if index < 0 or index >= size then
				return nil
			end
			item = item:getItem(index)
			if not item then
				return nil
			end
		end
		return item
	end
	if path.lootPouch == true then
		local pouch = select(1, findLootPouch(player))
		if not pouch then
			return nil
		end
		local indices = path.indices
		if type(indices) ~= "table" or #indices == 0 then
			return pouch
		end
		local item = pouch
		for _, rawIndex in ipairs(indices) do
			local index = tonumber(rawIndex)
			if index == nil or not item.getSize then
				return nil
			end
			local size = item:getSize() or 0
			if index < 0 or index >= size then
				return nil
			end
			item = item:getItem(index)
			if not item then
				return nil
			end
		end
		return item
	end
	local slot = tonumber(path.slot) or 0
	if slot <= 0 then
		return nil
	end
	local item = player:getSlotItem(slot)
	if not item then
		return nil
	end
	local indices = path.indices
	if type(indices) ~= "table" or #indices == 0 then
		return item
	end
	for _, rawIndex in ipairs(indices) do
		local index = tonumber(rawIndex)
		if index == nil or not item.getSize then
			return nil
		end
		local size = item:getSize() or 0
		if index < 0 or index >= size then
			return nil
		end
		item = item:getItem(index)
		if not item then
			return nil
		end
	end
	return item
end

--- Require controller and target share the same account (and account is non-zero).
function TeamManager.requireSameAccount(controller, target)
	if not controller or not target then
		return false, "Invalid request."
	end
	local ca = controller:getAccountId()
	local ta = target:getAccountId()
	if not ca or ca == 0 or not ta or ta == 0 then
		return false, "No account."
	end
	if ca ~= ta then
		return false, "Characters must be on your account."
	end
	return true
end

local function sameAccount(a, b)
	return a and b and a:getAccountId() == b:getAccountId() and a:getAccountId() > 0
end

local function isHeadlessCompanion(player)
	if not player then
		return false
	end
	local ctrl = player:getStorageValue(TeamConfig.STORAGE_COMPANION_CONTROLLER)
	return ctrl and ctrl > 0
end

--- True only when a live ProtocolGame UI is attached (not headless / protocol 0).
local function isRealUiClient(player)
	if not player then
		return false
	end
	if isHeadlessCompanion(player) then
		return false
	end
	if player.isHeadless and player:isHeadless() then
		return false
	end
	if player.getProtocolVersion and player:getProtocolVersion() == 0 then
		return false
	end
	return true
end

local function markCompanion(companion, controller)
	if not companion or not controller then
		return
	end
	companion:setStorageValue(TeamConfig.STORAGE_COMPANION_CONTROLLER, controller:getGuid())
end

local function clearCompanionMark(companion)
	if companion then
		companion:setStorageValue(TeamConfig.STORAGE_COMPANION_CONTROLLER, -1)
	end
end

--- Steal/reform party so controller is leader. force=true allows taking from a live UI host (pass/attach).
local function takePartyLeadership(controller, party, force)
	if not controller or not party then
		return nil, false, false
	end
	local leader = party:getLeader()
	if leader and leader:getId() == controller:getId() then
		return party, false, true
	end
	local leaderIsAbandonedHeadless = leader
		and sameAccount(leader, controller)
		and not isRealUiClient(leader)
	if not force and not leaderIsAbandonedHeadless then
		return nil, false, false
	end
	logger.info(
		"[Team] {} taking party leadership from {} (force={})",
		controller:getName(),
		leader and leader:getName() or "?",
		tostring(force == true)
	)
	local transferred = false
	local inParty = false
	for _, m in ipairs(party:getMembers() or {}) do
		if m and m:getId() == controller:getId() then
			inParty = true
			break
		end
	end
	if not inParty and leader and leader:getId() == controller:getId() then
		inParty = true
	end
	if not inParty then
		pcall(function()
			party:addInvite(controller)
			party:addMember(controller)
		end)
		inParty = controller:getParty() == party
	end
	if inParty and party.setLeader then
		local okSet = pcall(function()
			party:setLeader(controller)
		end)
		local newLeader = party.getLeader and party:getLeader() or nil
		transferred = okSet and newLeader and newLeader:getId() == controller:getId()
	end
	if transferred then
		return party, false, true
	end
	pcall(function()
		party:disband()
	end)
	local newParty = Party(controller)
	if not newParty then
		return nil, false, false
	end
	return newParty, true, true
end

--- Ensure controller leads a party that includes all companions (reforms after switch cleanup).
--- opts.force: take leadership even from a real-UI same-account leader (pass/attach/logout).
--- Returns party, partyOwned, errMessage
local function ensureControllerParty(controller, companions, opts)
	companions = companions or {}
	opts = opts or {}
	local force = opts.force == true
	local party = controller:getParty()
	local partyOwned = false

	if party then
		local leader = party:getLeader()
		if not leader or leader:getId() ~= controller:getId() then
			local newParty, owned, ok = takePartyLeadership(controller, party, force)
			if not ok then
				return nil, false, "Only the party leader can deploy an account team."
			end
			party = newParty
			partyOwned = owned
			if not party then
				return nil, false, "Failed to create party for team."
			end
		end
	elseif #companions > 0 then
		party = Party(controller)
		if not party then
			return nil, false, "Failed to create party for team."
		end
		partyOwned = true
	end

	if not party then
		return nil, false, nil
	end

	for _, companion in ipairs(companions) do
		if companion and companion.getId then
			local already = false
			local leader = party:getLeader()
			if leader and leader:getId() == companion:getId() then
				already = true
			end
			if not already then
				for _, m in ipairs(party:getMembers() or {}) do
					if m and m:getId() == companion:getId() then
						already = true
						break
					end
				end
			end
			if not already then
				local old = companion:getParty()
				if old and old ~= party then
					pcall(function()
						old:removeMember(companion)
					end)
				end
				local invited = party:addInvite(companion)
				local joined = party:addMember(companion)
				if not joined then
					pcall(function()
						party:addInvite(companion)
						joined = party:addMember(companion)
					end)
				end
				if not joined then
					logger.warn(
						"[Team] {} failed to party-join companion {} (invite={} joined={}); expedition will still pull them via deploy list",
						controller:getName(),
						companion:getName(),
						tostring(invited),
						tostring(joined)
					)
				end
			end
		end
	end
	if party.setSharedExperience then
		party:setSharedExperience(true)
	end
	return party, partyOwned, nil
end

-- Lua onDeath precedes C++ death penalties; wait for HP restore before save+logout.
local COMPANION_LOGOUT_DEFER_MS = 350
local COMPANION_LOGOUT_MAX_WAIT_MS = 3000
local COMPANION_LOGOUT_POLL_MS = 100
-- playerId → generation; bumping cancels an in-flight deferred logout (switch redeploy).
local pendingCompanionLogoutGen = {}

local function safeLogoutCompanion(companion, deferMs)
	if not companion or not isHeadlessCompanion(companion) then
		return
	end
	local playerId = companion:getId()
	local startedMs = os.mtime and os.mtime() or (os.time() * 1000)
	local gen = (pendingCompanionLogoutGen[playerId] or 0) + 1
	pendingCompanionLogoutGen[playerId] = gen

	local function logoutNow()
		local c = Player(playerId)
		if not c or not isHeadlessCompanion(c) then
			return
		end
		clearCompanionMark(c)
		if type(Game.headlessLogout) == "function" then
			Game.headlessLogout(c)
		end
	end

	local function tryLogout()
		if pendingCompanionLogoutGen[playerId] ~= gen then
			return
		end
		local c = Player(playerId)
		if not c or not isHeadlessCompanion(c) then
			pendingCompanionLogoutGen[playerId] = nil
			return
		end
		local hp = c.getHealth and c:getHealth() or 0
		local nowMs = os.mtime and os.mtime() or (os.time() * 1000)
		if hp <= 0 and (nowMs - startedMs) < COMPANION_LOGOUT_MAX_WAIT_MS then
			addEvent(tryLogout, COMPANION_LOGOUT_POLL_MS)
			return
		end
		pendingCompanionLogoutGen[playerId] = nil
		logoutNow()
	end

	local initialDelay = tonumber(deferMs)
	if initialDelay == nil then
		initialDelay = COMPANION_LOGOUT_DEFER_MS
	end
	if companion.getHealth and companion:getHealth() <= 0 and initialDelay < COMPANION_LOGOUT_DEFER_MS then
		initialDelay = COMPANION_LOGOUT_DEFER_MS
	end
	if initialDelay <= 0 then
		tryLogout()
		return
	end
	addEvent(tryLogout, initialDelay)
end

--- Cancel a deferred companion logout (e.g. leave→switch redeploy reused the same creature).
function TeamManager.cancelCompanionLogout(companionOrId)
	local playerId = companionOrId
	if type(companionOrId) ~= "number" then
		if not companionOrId or not companionOrId.getId then
			return
		end
		playerId = companionOrId:getId()
	end
	if not playerId then
		return
	end
	pendingCompanionLogoutGen[playerId] = (pendingCompanionLogoutGen[playerId] or 0) + 1
end

function TeamManager.getCompanionController(companion)
	if not companion or not isHeadlessCompanion(companion) then
		return nil
	end
	local guid = companion:getStorageValue(TeamConfig.STORAGE_COMPANION_CONTROLLER)
	if not guid or guid <= 0 then
		return nil
	end
	return Player(guid)
end

function TeamManager.isCompanion(player)
	return isHeadlessCompanion(player)
end

function TeamManager.isRealUiClient(player)
	return isRealUiClient(player)
end

function TeamManager.markCompanion(companion, controller)
	markCompanion(companion, controller)
end

--- Keep Party leader aligned with account-team host after every host change.
function TeamManager.syncPartyLeaderToTeamHost(host, opts)
	if not host then
		return false
	end
	opts = opts or {}
	local companions = {}
	local seen = {}
	seen[host:getId()] = true

	local function addCompanion(p)
		if not p or not p.getId then
			return
		end
		local id = p:getId()
		if seen[id] then
			return
		end
		seen[id] = true
		companions[#companions + 1] = p
	end

	if TeamStore and TeamStore.getMembers then
		for _, entry in ipairs(TeamStore.getMembers(host) or {}) do
			if entry.name and entry.name:lower() ~= host:getName():lower() then
				addCompanion(Player(entry.name))
			end
		end
	end

	local party = host:getParty()
	if party then
		local leader = party:getLeader()
		if leader then
			addCompanion(leader)
		end
		for _, m in ipairs(party:getMembers() or {}) do
			addCompanion(m)
		end
	end

	local _, _, err = ensureControllerParty(host, companions, { force = opts.force == true })
	if err then
		logger.warn("[Team] syncPartyLeaderToTeamHost failed for {}: {}", host:getName(), tostring(err))
		return false
	end
	return true
end

--- Single path for team-host + party leadership transfer.
--- opts: fromHostGuid, force, reason ("pass"|"attach"|"detach"|"login"|"logout")
function TeamManager.transferLeadership(newHost, opts)
	opts = opts or {}
	if not newHost then
		return false, "No player."
	end

	local fromHostGuid = tonumber(opts.fromHostGuid) or 0
	local oldHost = nil
	if fromHostGuid > 0 then
		oldHost = TeamStore.resolvePlayerByGuid(fromHostGuid)
		if not oldHost and TeamStore.findOnlinePlayerByGuid then
			oldHost = TeamStore.findOnlinePlayerByGuid(fromHostGuid)
		end
	end
	if not oldHost then
		local controller = TeamStore.resolveTeamController(newHost)
		if controller and controller:getGuid() ~= newHost:getGuid() then
			oldHost = controller
			fromHostGuid = controller:getGuid()
		end
	end
	if not oldHost or oldHost:getGuid() == newHost:getGuid() then
		return false, "Nothing to transfer."
	end

	local accountId = newHost:getAccountId()
	if not accountId or accountId <= 0 or oldHost:getAccountId() ~= accountId then
		return false, "Different account."
	end

	-- Friends cannot own account-team KV.
	if TeamStore.isOnControllerRoster then
		local onRoster = TeamStore.isOnControllerRoster(newHost, oldHost)
		if not onRoster then
			local listed = ListingsStore and ListingsStore.playerOnHostListing and ListingsStore.playerOnHostListing(oldHost, newHost)
			if not listed and not opts.force then
				return false, "Not on team roster."
			end
		end
	end

	local force = opts.force == true
	if not force and TeamStore.isRealOnlineClient and TeamStore.isRealOnlineClient(oldHost:getGuid()) then
		return false, "Current host still has a UI client."
	end

	local oldGuid = oldHost:getGuid()
	local newGuid = newHost:getGuid()

	local ok = TeamStore.adoptAccountTeamLeadership(newHost, {
		force = true,
		fromHostGuid = oldGuid,
	})
	if not ok then
		return false, "Failed to adopt leadership."
	end

	if deployments[oldGuid] then
		deployments[newGuid] = deployments[oldGuid]
		deployments[oldGuid] = nil
	end

	local liveOld = TeamStore.findOnlinePlayerByGuid(oldGuid)
	if liveOld then
		markCompanion(liveOld, newHost)
		if not isRealUiClient(liveOld) and liveOld.setHeadless then
			liveOld:setHeadless(true)
		end
	end

	-- Match team-transfer force: login (no force) only takes party from abandoned headless.
	TeamManager.syncPartyLeaderToTeamHost(newHost, { force = force })

	if TeamProtocol and TeamProtocol.sendTeamToRoster then
		pcall(TeamProtocol.sendTeamToRoster, newHost)
	end
	if SocialProtocol and SocialProtocol.sendMyListing then
		pcall(SocialProtocol.sendMyListing, newHost)
		if liveOld and isRealUiClient(liveOld) then
			pcall(SocialProtocol.sendMyListing, liveOld)
		end
	end

	logger.info(
		"[Team] leadership transferred {} → {} (reason={})",
		oldHost:getName(),
		newHost:getName(),
		tostring(opts.reason or "transfer")
	)
	return true
end

--- Interactive pass from manage UI (host → same-account companion).
function TeamManager.passLeadership(host, targetName)
	if not host then
		return false, "No player."
	end
	if not TeamStore.canEditTeam(host) then
		return false, "Only the team host can pass leadership."
	end
	targetName = tostring(targetName or ""):match("^%s*(.-)%s*$") or ""
	if targetName == "" then
		return false, "No target."
	end
	if targetName:lower() == host:getName():lower() then
		return false, "Already the team host."
	end

	local target = Player(targetName)
	if not target then
		return false, "Target must be online."
	end
	if target:getAccountId() ~= host:getAccountId() then
		return false, "Can only pass leadership to same-account companions."
	end

	local onRoster = false
	for _, entry in ipairs(TeamStore.getMembers(host) or {}) do
		if entry.name and entry.name:lower() == targetName:lower() then
			if entry.kind == TeamConfig.KIND_FRIEND then
				return false, "Cannot pass leadership to friends."
			end
			onRoster = true
			break
		end
	end
	if not onRoster then
		return false, "Target is not on the team roster."
	end

	return TeamManager.transferLeadership(target, {
		fromHostGuid = host:getGuid(),
		force = true,
		reason = "pass",
	})
end

--- Clear companion mark while a UI client is attached (opcodes); pointer stays in TeamStore.
function TeamManager.onAttachedClient(player)
	if not player then
		return
	end
	if player.setHeadless then
		player:setHeadless(false)
	end
	if isHeadlessCompanion(player) then
		clearCompanionMark(player)
	end
end

--- Called from C++ ProtocolGame::connect after a real client attaches.
function TeamManager.onClientAttached(player)
	if not player then
		return
	end
	TeamManager.onAttachedClient(player)

	local controller = TeamStore.resolveTeamController(player)
	if controller and controller:getGuid() == player:getGuid() then
		TeamManager.syncPartyLeaderToTeamHost(player, { force = true })
		if TeamProtocol and TeamProtocol.sendTeamToRoster then
			pcall(TeamProtocol.sendTeamToRoster, player)
		end
		if SocialProtocol and SocialProtocol.sendMyListing then
			pcall(SocialProtocol.sendMyListing, player)
		end
	else
		local host = controller
		local hostGuid = host and host:getGuid() or 0
		local hostIsReal = hostGuid > 0 and TeamStore.isRealOnlineClient and TeamStore.isRealOnlineClient(hostGuid)
		if host and not hostIsReal then
			pcall(TeamManager.transferLeadership, player, {
				fromHostGuid = hostGuid,
				force = true,
				reason = "attach",
			})
		else
			if TeamProtocol and TeamProtocol.sendTeam then
				pcall(TeamProtocol.sendTeam, player)
			end
			if SocialProtocol and SocialProtocol.sendMyListing then
				pcall(SocialProtocol.sendMyListing, player)
			end
		end
	end

	if ExpeditionManager and ExpeditionManager.syncSessionClientIfNeeded then
		pcall(ExpeditionManager.syncSessionClientIfNeeded, player)
	end
end

--- Called from C++ when a real client detaches and the creature stays online as headless.
--- Restores same-account companion mark so expedition/team treat them as companions again.
function TeamManager.onBecameHeadless(player)
	if not player then
		return
	end
	if player.setHeadless then
		player:setHeadless(true)
	end
	if TeamStore and TeamStore.reconcileControllerPointer then
		pcall(TeamStore.reconcileControllerPointer, player)
	end
	local hostGuid = TeamStore and TeamStore.getControllerPointer and TeamStore.getControllerPointer(player) or nil
	hostGuid = tonumber(hostGuid) or 0
	if hostGuid <= 0 or hostGuid == player:getGuid() then
		return
	end
	local host = TeamStore.findOnlinePlayerByGuid and TeamStore.findOnlinePlayerByGuid(hostGuid) or Player(hostGuid)
	if not host or host:getId() == player:getId() then
		return
	end
	if not sameAccount(host, player) then
		return
	end
	if TeamStore.isOnControllerRoster and not TeamStore.isOnControllerRoster(player, host) then
		return
	end
	markCompanion(player, host)
	-- Keep expedition session membership as companion (blocks accept prompts).
	if ExpeditionManager and ExpeditionManager.getSessionByPlayer then
		local session = ExpeditionManager.getSessionByPlayer(player)
			or ExpeditionManager.getSessionByPlayer(host)
		if session then
			session.companionIds = session.companionIds or {}
			session.companionIds[player:getId()] = true
			if session.memberGuids then
				session.memberGuids[player:getGuid()] = player:getId()
			end
		end
	end
	logger.info(
		"[Team] {} became headless companion under {}",
		player:getName(),
		host:getName()
	)
end

--- Called from C++ ProtocolGame::release when the creature stays online without a UI.
function TeamManager.onClientDetached(player)
	if not player then
		return
	end

	local wasHost = TeamStore.canEditTeam(player)
	TeamManager.onBecameHeadless(player)

	if not wasHost then
		return
	end

	local successor = nil
	if ListingsStore and ListingsStore.findOnlineAccountSuccessor then
		successor = ListingsStore.findOnlineAccountSuccessor(player)
	end
	if not successor then
		-- Host remains headless team host + party leader (hunt continues).
		return
	end

	pcall(TeamManager.transferLeadership, successor, {
		fromHostGuid = player:getGuid(),
		force = true,
		reason = "detach",
	})
end

function TeamManager.safeLogoutCompanion(companion, deferMs)
	safeLogoutCompanion(companion, deferMs)
end

function TeamManager.getDeployment(controller)
	if not controller then
		return nil
	end
	return deployments[controller:getGuid()]
end

function TeamManager.getTeamInfo(player)
	local controller = TeamStore.resolveTeamController(player)
	if not controller then
		controller = player
	end
	local membersCfg = TeamStore.getMembers(player)
	local members = {}
	local deployed = TeamManager.getDeployment(controller) ~= nil
	for _, entry in ipairs(membersCfg) do
		local name = entry.name
		local kind = entry.kind or TeamConfig.KIND_COMPANION
		local p = Player(name)
		local offline = nil
		if not p then
			offline = Game.getOfflinePlayer(name)
		end
		local src = p or offline
		local profile = memberProfileWire(src)
		members[#members + 1] = {
			name = name,
			guid = src and src:getGuid() or 0,
			level = profile.level,
			vocation = profile.vocation,
			outfit = profile.outfit,
			online = p ~= nil,
			kind = kind,
			companion = p and isHeadlessCompanion(p) or false,
			isPrimary = name == controller:getName(),
			isFriend = kind == TeamConfig.KIND_FRIEND,
		}
	end
	local pendingRosterInvites = {}
	for friendGuid, invite in pairs(rosterInvitesByFriendGuid) do
		if invite and invite.hostGuid == controller:getGuid() then
			local friend = Player(friendGuid)
			pendingRosterInvites[#pendingRosterInvites + 1] = {
				guid = friendGuid,
				name = (friend and friend:getName()) or invite.friendName or tostring(friendGuid),
			}
		end
	end
	return {
		members = members,
		deployed = deployed,
		canEdit = TeamStore.canEditTeam(player),
		teamHostName = controller:getName(),
		pendingRosterInvites = pendingRosterInvites,
	}
end

function TeamManager.addFriendToRoster(host, friend)
	if not host or not friend then
		return false
	end
	local friendName = friend.getName and friend:getName() or tostring(friend)
	local members = TeamStore.getMembers(host)
	for _, entry in ipairs(members) do
		if entry.name and entry.name:lower() == friendName:lower() then
			return true
		end
	end
	if #members >= (TeamConfig.MAX_MEMBERS or 4) then
		return false, "Team is full."
	end
	members[#members + 1] = { name = friendName, kind = TeamConfig.KIND_FRIEND }
	local ok, err = TeamManager.setMembers(host, members, { allowFriends = true })
	if not ok then
		return false, err
	end
	return true
end

--- Add same-account character to the account team roster (online or offline).
function TeamManager.addCompanionToRoster(host, companionOrName)
	if not host or not companionOrName then
		return false, "Invalid request."
	end
	if not TeamStore.canEditTeam(host) then
		return false, "Only the team host can edit the roster."
	end
	local companion, err
	if type(companionOrName) == "userdata" and companionOrName.getName then
		companion, err = TeamStore.resolveAccountMember(host, companionOrName:getName())
	elseif type(companionOrName) == "number" then
		companion, err = TeamStore.resolveAccountMember(host, companionOrName)
	else
		companion, err = TeamStore.resolveAccountMember(host, companionOrName)
	end
	if not companion then
		return false, err or "Character is not on your account."
	end
	if companion:getGuid() == host:getGuid() then
		return true
	end
	local members = TeamStore.getMembers(host)
	local name = companion:getName()
	for _, entry in ipairs(members) do
		if entry.name and entry.name:lower() == name:lower() then
			TeamStore.setControllerPointer(companion, host:getGuid())
			return true
		end
	end
	if #members >= (TeamConfig.MAX_MEMBERS or 4) then
		return false, "Team is full."
	end
	members[#members + 1] = { name = name, kind = TeamConfig.KIND_COMPANION }
	local ok, saveErr = TeamStore.setMembersOnController(host, members)
	if not ok then
		return false, saveErr
	end
	return true
end

--- After a listing accept: sync account roster (companion) or friend roster as appropriate.
function TeamManager.syncRosterAfterListingAccept(host, joinerPlayerOrName)
	if not host or not joinerPlayerOrName then
		return false
	end
	local joiner = joinerPlayerOrName
	if type(joiner) ~= "userdata" or not joiner.getAccountId then
		joiner = TeamStore.resolveCharacter(joinerPlayerOrName)
	end
	if not joiner then
		return false
	end
	if joiner:getAccountId() == host:getAccountId() then
		return TeamManager.addCompanionToRoster(host, joiner)
	end
	if TeamStore.resolveFriendMember and TeamStore.resolveFriendMember(host, joiner:getName()) then
		return TeamManager.addFriendToRoster(host, joiner)
	end
	return false
end

function TeamManager.inviteRosterFriend(host, friendName)
	if not host then
		return false, "No player."
	end
	if not TeamStore.canEditTeam(host) then
		return false, "Only the team host can invite friends."
	end
	if not ListingsStore or not ListingsStore.getByHost or not ListingsStore.getByHost(host) then
		return false, "Start assembling a team before inviting friends."
	end
	local friend, err = TeamStore.resolveFriendMember(host, friendName)
	if not friend then
		return false, err or "Only friends can join your team."
	end
	if friend:getGuid() == host:getGuid() then
		return false, "Cannot invite yourself."
	end
	local members = TeamStore.getMembers(host)
	if #members >= (TeamConfig.MAX_MEMBERS or 4) then
		return false, "Team is full."
	end
	for _, entry in ipairs(members) do
		if entry.name and entry.name:lower() == friend:getName():lower() then
			return false, "That friend is already on your team."
		end
	end
	if rosterInvitesByFriendGuid[friend:getGuid()] then
		return false, "That friend already has a pending team invite."
	end
	if not Player(friend:getGuid()) then
		return false, "Friend must be online to receive a team invite."
	end
	rosterInvitesByFriendGuid[friend:getGuid()] = {
		hostGuid = host:getGuid(),
		hostName = host:getName(),
		friendName = friend:getName(),
		expires = os.time() + 300,
	}
	TeamProtocol.send(friend, {
		type = "teamRosterInvite",
		hostName = host:getName(),
		hostGuid = host:getGuid(),
	})
	friend:sendTextMessage(
		MESSAGE_EVENT_ADVANCE,
		string.format("%s invited you to their account team. Accept from the team panel.", host:getName())
	)
	TeamProtocol.sendTeam(host)
	return true, { name = friend:getName() }
end

function TeamManager.acceptRosterInvite(friend)
	if not friend then
		return false, "No player."
	end
	local invite = rosterInvitesByFriendGuid[friend:getGuid()]
	if not invite then
		return false, "No pending team invite."
	end
	if invite.expires and os.time() > invite.expires then
		rosterInvitesByFriendGuid[friend:getGuid()] = nil
		return false, "That team invite expired."
	end
	local host = Player(invite.hostGuid)
	if not host then
		rosterInvitesByFriendGuid[friend:getGuid()] = nil
		return false, "Team host is offline."
	end
	rosterInvitesByFriendGuid[friend:getGuid()] = nil
	local ok, err = TeamManager.addFriendToRoster(host, friend)
	if not ok then
		return false, err or "Failed to join team."
	end
	TeamProtocol.send(friend, { type = "teamRosterInviteCleared" })
	TeamProtocol.sendTeam(host)
	TeamProtocol.sendTeam(friend)
	friend:sendTextMessage(
		MESSAGE_EVENT_ADVANCE,
		string.format("You joined %s's account team.", host:getName())
	)
	host:sendTextMessage(
		MESSAGE_EVENT_ADVANCE,
		string.format("%s joined your account team.", friend:getName())
	)
	return true
end

function TeamManager.declineRosterInvite(friend)
	if not friend then
		return
	end
	local invite = rosterInvitesByFriendGuid[friend:getGuid()]
	rosterInvitesByFriendGuid[friend:getGuid()] = nil
	TeamProtocol.send(friend, { type = "teamRosterInviteCleared" })
	if invite and invite.hostGuid then
		local host = Player(invite.hostGuid)
		if host then
			host:sendTextMessage(
				MESSAGE_EVENT_ADVANCE,
				string.format("%s declined your team invite.", friend:getName())
			)
			TeamProtocol.sendTeam(host)
		end
	end
end

function TeamManager.setMembers(player, members, opts)
	opts = opts or {}
	if not TeamStore.canEditTeam(player) then
		return false, "Only the team host can edit the roster."
	end
	local preview = TeamStore.sanitizeMembers(player, members)
	if not opts.allowFriends then
		for i = 2, #preview do
			if preview[i].kind == TeamConfig.KIND_FRIEND then
				return false, "Invite friends to the team; they must accept first."
			end
		end
	end
	-- Adding companions/friends requires an assembled (listed) team.
	if #preview > 1 then
		if not ListingsStore or not ListingsStore.getByHost or not ListingsStore.getByHost(player) then
			return false, "Start assembling a team before adding members."
		end
	end
	local previous = TeamStore.getMembers(player)
	local ok, result = TeamStore.setMembers(player, members)
	if not ok then
		return false, result
	end
	-- Validate each non-primary entry by kind.
	for i = 2, #result do
		local entry = result[i]
		if entry.kind == TeamConfig.KIND_FRIEND then
			local friend, err = TeamStore.resolveFriendMember(player, entry.name)
			if not friend then
				-- Never wipe companions/friends on a failed add — restore prior roster.
				TeamStore.setMembers(player, previous)
				return false, err or ("Unknown friend: " .. tostring(entry.name))
			end
			-- Normalize stored name to canonical character name.
			entry.name = friend:getName()
		else
			local member, err = TeamStore.resolveAccountMember(player, entry.name)
			if not member then
				TeamStore.setMembers(player, previous)
				return false, err or ("Unknown character: " .. tostring(entry.name))
			end
			entry.name = member:getName()
		end
	end
	-- Re-persist normalized names.
	local saved, saveErr = TeamStore.setMembers(player, result)
	if not saved then
		TeamStore.setMembers(player, previous)
		return false, saveErr
	end
	return true, saved
end

--- Unlist / disassemble: undeploy companions and reset roster to primary only.
function TeamManager.disassemble(player)
	if not player then
		return false, "No player."
	end
	if TeamManager.getDeployment(player) then
		pcall(function()
			TeamManager.undeploy(player)
		end)
	end
	return TeamStore.setMembers(player, {
		{ name = player:getName(), kind = TeamConfig.KIND_COMPANION },
	})
end

--- Leave / disband friend's current party, then force-join host party.
function TeamManager.forceJoinFriendToParty(host, friend)
	if not host or not friend then
		return false, "Invalid request."
	end
	if host:getId() == friend:getId() then
		return false, "Cannot join yourself."
	end

	local old = friend:getParty()
	if old then
		local leader = old:getLeader()
		local others = 0
		for _, m in ipairs(old:getMembers() or {}) do
			if m and m:getId() ~= friend:getId() then
				others = others + 1
			end
		end
		if leader and leader:getId() == friend:getId() and others == 0 then
			pcall(function()
				old:disband()
			end)
		else
			pcall(function()
				old:removeMember(friend)
			end)
		end
	end

	local party = host:getParty()
	if not party then
		party = Party(host)
		if not party then
			return false, "Failed to create expedition party."
		end
	else
		local leader = party:getLeader()
		if not leader or leader:getId() ~= host:getId() then
			return false, "Host must lead the expedition party."
		end
	end

	local already = false
	local leader = party:getLeader()
	if leader and leader:getId() == friend:getId() then
		already = true
	end
	if not already then
		for _, m in ipairs(party:getMembers() or {}) do
			if m and m:getId() == friend:getId() then
				already = true
				break
			end
		end
	end
	if already then
		return true
	end

	party:addInvite(friend)
	local joined = party:addMember(friend)
	if not joined then
		pcall(function()
			party:addInvite(friend)
			joined = party:addMember(friend)
		end)
	end
	if not joined then
		return false, "Failed to join expedition party."
	end
	if party.setSharedExperience then
		party:setSharedExperience(true)
	end
	return true
end

--- Soft-invite online friends on the roster into the host party (no force-join).
function TeamManager.inviteFriends(controller)
	if not controller then
		return false, "No player."
	end
	local party = controller:getParty()
	if not party then
		party = Party(controller)
		if not party then
			return false, "Failed to create party."
		end
	else
		local leader = party:getLeader()
		if not leader or leader:getId() ~= controller:getId() then
			return false, "Only the party leader can invite team friends."
		end
	end

	local invited = {}
	local skipped = {}
	for _, name in ipairs(TeamStore.getFriendNames(controller)) do
		local friend = Player(name)
		if not friend then
			skipped[#skipped + 1] = { name = name, reason = "offline" }
		elseif not TeamStore.isFriend(controller, friend:getGuid()) then
			skipped[#skipped + 1] = { name = name, reason = "not_friend" }
		else
			local already = false
			local leader = party:getLeader()
			if leader and leader:getId() == friend:getId() then
				already = true
			end
			if not already then
				for _, m in ipairs(party:getMembers() or {}) do
					if m and m:getId() == friend:getId() then
						already = true
						break
					end
				end
			end
			if already then
				invited[#invited + 1] = { name = name, status = "already" }
			else
				party:addInvite(friend)
				invited[#invited + 1] = { name = name, status = "invited" }
			end
		end
	end
	return true, { invited = invited, skipped = skipped }
end

--- Login configured companions, ensure party under primary as leader.
--- `opts.position`: spawn/teleport companions here (e.g. expedition entry).
--- `opts.inviteFriends`: when true (default for world form), soft-invite friends.
--- `opts.companionsOnly`: when true, skip friend invites (expedition host uses separate friend flow).
--- Returns companions list or nil + error.
local function applyCompanionAutoRebuy(companion)
	if not companion or not RemoteBlessings or not RemoteBlessings.tryAutoRebuy then
		return
	end
	local companionId = companion:getId()
	addEvent(function()
		local c = Player(companionId)
		if c then
			pcall(RemoteBlessings.tryAutoRebuy, c)
		end
	end, 0)
end

--- Finalize party / deployment bookkeeping after companions are online.
--- @return companions, err
local function finalizeDeploy(controller, opts, companions)
	local party, partyOwned, partyErr = ensureControllerParty(controller, companions)
	if partyErr then
		for _, c in ipairs(companions) do
			if isHeadlessCompanion(c) then
				clearCompanionMark(c)
				Game.headlessLogout(c)
			end
		end
		return nil, partyErr
	end
	if not party and (opts.inviteFriends and not opts.companionsOnly) then
		party = Party(controller)
		if not party then
			return nil, "Failed to create party for team."
		end
		partyOwned = true
		if party.setSharedExperience then
			party:setSharedExperience(true)
		end
	end

	local ids = {}
	for _, c in ipairs(companions) do
		ids[#ids + 1] = c:getId()
	end
	if #ids > 0 then
		deployments[controller:getGuid()] = {
			companionIds = ids,
			partyOwned = partyOwned,
		}
	elseif partyOwned and party then
		deployments[controller:getGuid()] = {
			companionIds = {},
			partyOwned = true,
		}
	end

	if opts.inviteFriends ~= false and not opts.companionsOnly then
		TeamManager.inviteFriends(controller)
	end

	logger.info(
		"[Team] {} deployed {} companion(s)",
		controller:getName(),
		#companions
	)
	for _, companion in ipairs(companions) do
		applyCompanionAutoRebuy(companion)
	end
	return companions
end

local function deliverDeployResult(opts, companions, err)
	if opts and opts.onComplete then
		opts.onComplete(companions, err)
		-- Async/callback API: truthy first return means the request was accepted.
		return companions ~= nil, err
	end
	return companions, err
end

local function rollbackCompanions(companions)
	for _, c in ipairs(companions or {}) do
		clearCompanionMark(c)
		if isHeadlessCompanion(c) then
			safeLogoutCompanion(c)
		end
	end
end

local function claimOnlineCompanion(controller, online, spawnPos, opts)
	if online.getHealth and online:getHealth() <= 0 then
		safeLogoutCompanion(online)
		return nil
	end
	TeamManager.cancelCompanionLogout(online)
	local onlineGuid = online.getGuid and online:getGuid() or 0
	if onlineGuid > 0 and deployments[onlineGuid] then
		deployments[onlineGuid] = nil
	end
	local onlineParty = online.getParty and online:getParty() or nil
	if onlineParty then
		local leader = onlineParty.getLeader and onlineParty:getLeader() or nil
		if not (leader and leader:getId() == online:getId()) then
			pcall(function()
				onlineParty:removeMember(online)
			end)
		end
	end
	if opts.position then
		if opts.instanceId then
			online:teleportTo(spawnPos, false, opts.instanceId)
		else
			online:teleportTo(spawnPos)
		end
	elseif opts.instanceId then
		logger.warn(
			"[Team] refusing same-tile instance rebind for {} (pass opts.position)",
			online:getName()
		)
	end
	markCompanion(online, controller)
	if online.setHeadless then
		online:setHeadless(true)
	end
	logger.info(
		"[Team] {} claimed headless {} as companion",
		controller:getName(),
		online:getName()
	)
	return online
end

local function acceptLoadedCompanions(controller, companions, loaded, accountId)
	for _, companion in ipairs(loaded or {}) do
		if not companion then
			rollbackCompanions(companions)
			return nil, "Failed to login companion."
		end
		if companion:getAccountId() ~= accountId then
			rollbackCompanions(companions)
			if isHeadlessCompanion(companion) then
				safeLogoutCompanion(companion)
			end
			return nil, string.format("%s is not on your account.", companion:getName())
		end
		markCompanion(companion, controller)
		companions[#companions + 1] = companion
	end
	return companions
end

--- Deploy account companions near the controller.
--- opts.position: spawn/teleport companions here (e.g. expedition entry).
--- opts.instanceId: bind private hunt/raid id before place (atomic with headlessLogin).
--- opts.onComplete = function(companions|nil, err|nil) — required; DB loads are async via headlessLoginBatch.
function TeamManager.deploy(controller, opts)
	opts = opts or {}
	if not controller then
		return deliverDeployResult(opts, nil, "No player.")
	end
	if type(opts.onComplete) ~= "function" then
		return deliverDeployResult(opts, nil, "Team deploy requires async onComplete.")
	end
	if not Game.headlessLoginBatch then
		return deliverDeployResult(opts, nil, "Headless login batch is not available on this server build.")
	end

	local spawnPos = opts.position or controller:getPosition()
	local instanceId = math.floor(tonumber(opts.instanceId) or 0)
	local accountId = controller:getAccountId()

	local existing = deployments[controller:getGuid()]
	if existing then
		local live = {}
		local liveByName = {}
		for _, id in ipairs(existing.companionIds or {}) do
			local p = Player(id)
			if p then
				if isHeadlessCompanion(p) and p.getHealth and p:getHealth() <= 0 then
					safeLogoutCompanion(p)
					p = nil
				end
				if p then
					TeamManager.cancelCompanionLogout(p)
					if opts.position then
						if opts.instanceId then
							p:teleportTo(spawnPos, false, opts.instanceId)
						else
							p:teleportTo(spawnPos)
						end
					elseif opts.instanceId then
						logger.warn(
							"[Team] refusing same-tile instance rebind for {} (pass opts.position)",
							p:getName()
						)
					end
					live[#live + 1] = p
					liveByName[p:getName():lower()] = true
				end
			end
		end
		local members = TeamStore.getMembers(controller)
		for i = 2, #members do
			local entry = members[i]
			if entry.kind ~= TeamConfig.KIND_FRIEND and not liveByName[entry.name:lower()] then
				local online = Player(entry.name)
				if not (online and isRealUiClient(online)) then
					deployments[controller:getGuid()] = nil
					return TeamManager.deploy(controller, opts)
				end
			end
		end
		if opts.inviteFriends and not opts.companionsOnly then
			TeamManager.inviteFriends(controller)
		end
		local party, _, partyErr = ensureControllerParty(controller, live)
		if partyErr then
			return deliverDeployResult(opts, nil, partyErr)
		end
		if party and existing then
			existing.partyOwned = existing.partyOwned or false
		end
		for _, p in ipairs(live) do
			applyCompanionAutoRebuy(p)
		end
		return deliverDeployResult(opts, live, nil)
	end

	local members = TeamStore.getMembers(controller)
	members = TeamStore.sanitizeMembers(controller, members)
	local companions = {}
	local namesToLoad = {}

	for i = 2, #members do
		local entry = members[i]
		if entry.kind == TeamConfig.KIND_FRIEND then
			-- Friends are never headless-logged in.
		else
			local name = entry.name
			if name:lower() == controller:getName():lower() then
				-- Never headless-login the deployer.
			else
				local online = Player(name)
				if online and online.getId and online:getId() == controller:getId() then
					-- Deployer listed as companion (stale roster) — ignore.
				elseif online and isRealUiClient(online) then
					logger.info(
						"[Team] {} skip companion deploy for {} (already on a real client)",
						controller:getName(),
						name
					)
				elseif online then
					local claimed = claimOnlineCompanion(controller, online, spawnPos, opts)
					if claimed then
						companions[#companions + 1] = claimed
					else
						-- Died/logged out during claim — treat as offline load.
						local offline = Game.getOfflinePlayer(name)
						if not offline then
							rollbackCompanions(companions)
							return deliverDeployResult(opts, nil, string.format("Character not found: %s", name))
						end
						if offline:getAccountId() ~= accountId then
							rollbackCompanions(companions)
							return deliverDeployResult(opts, nil, string.format("%s is not on your account.", name))
						end
						namesToLoad[#namesToLoad + 1] = name
					end
				else
					local offline = Game.getOfflinePlayer(name)
					if not offline then
						rollbackCompanions(companions)
						return deliverDeployResult(opts, nil, string.format("Character not found: %s", name))
					end
					if offline:getAccountId() ~= accountId then
						rollbackCompanions(companions)
						return deliverDeployResult(opts, nil, string.format("%s is not on your account.", name))
					end
					namesToLoad[#namesToLoad + 1] = name
				end
			end
		end
	end

	local function finishWithCompanions(list)
		local finalized, ferr = finalizeDeploy(controller, opts, list)
		return deliverDeployResult(opts, finalized, ferr)
	end

	if #namesToLoad == 0 then
		return finishWithCompanions(companions)
	end

	local claimed = companions
	Game.headlessLoginBatch(namesToLoad, spawnPos, function(loaded, loadErr)
		if not controller or not Player(controller:getId()) then
			for _, c in ipairs(loaded or {}) do
				if c and isHeadlessCompanion(c) then
					safeLogoutCompanion(c)
				end
			end
			opts.onComplete(nil, "Controller offline during deploy.")
			return
		end
		if not loaded then
			rollbackCompanions(claimed)
			opts.onComplete(nil, loadErr or "Failed to login companions.")
			return
		end
		local merged, mergeErr = acceptLoadedCompanions(controller, claimed, loaded, accountId)
		if not merged then
			opts.onComplete(nil, mergeErr)
			return
		end
		local finalized, ferr = finalizeDeploy(controller, opts, merged)
		opts.onComplete(finalized, ferr)
	end, instanceId)
	return true
end

function TeamManager.undeploy(controller, opts)
	opts = opts or {}
	if not controller then
		return
	end
	local dep = deployments[controller:getGuid()]
	if not dep then
		return
	end

	local party = controller:getParty()
	for _, id in ipairs(dep.companionIds or {}) do
		local companion = Player(id)
		if companion then
			if isHeadlessCompanion(companion) then
				-- headlessLogout → removeCreature → onRemoveCreature leaveParty (force).
				-- Avoid party:removeMember first; double leave/disband can desync map sectors.
				if opts.returnPos then
					pcall(function()
						companion:teleportTo(opts.returnPos)
					end)
				end
				-- Voluntary undeploy: logout immediately so leave→switch cannot redeploy
				-- the same creature and then hit a deferred logout as a false hunt death.
				-- Death paths still pass deferMs (default 350ms) via safeLogoutCompanion.
				local deferMs = 0
				if companion.getHealth and companion:getHealth() <= 0 then
					deferMs = nil
				end
				safeLogoutCompanion(companion, deferMs)
			elseif party and companion:getParty() == party then
				pcall(function()
					party:removeMember(companion)
				end)
			end
		end
	end

	-- Headless logout already leaveParty'd; disband only if the host still owns this party.
	if dep.partyOwned and party and controller:getParty() == party then
		local members = party:getMembers()
		local onlyLeader = true
		if type(members) == "table" then
			for _, m in ipairs(members) do
				if m and m:getId() ~= controller:getId() then
					onlyLeader = false
					break
				end
			end
		end
		if onlyLeader then
			pcall(function()
				party:disband()
			end)
		end
	end

	deployments[controller:getGuid()] = nil
	logger.info("[Team] {} undeployed companions", controller:getName())
end

function TeamManager.getInventorySnapshot(controller, nameOrGuid)
	local target, err = TeamStore.resolveAccountMember(controller, nameOrGuid or controller:getName())
	if not target then
		return nil, err
	end

	local equipment = {}
	for _, slot in ipairs(TeamConfig.EQUIP_SLOTS or {}) do
		local it = target:getSlotItem(slot.id)
		equipment[#equipment + 1] = {
			slot = slot.id,
			slotName = slot.name,
			item = itemWire(it, { slot = slot.id }),
		}
	end

	local backpack = target:getSlotItem(CONST_SLOT_BACKPACK)
	local bagItems = {}
	local backpackPath = { slot = CONST_SLOT_BACKPACK }
	if backpack and backpack.getSize then
		bagItems = containerWire(backpack, backpackPath, 60)
	end

	-- Offline players from getOfflinePlayer need save only when modified.
	local wasOnline = Player(target:getName()) ~= nil

	local creatureId = 0
	local live = Player(target:getName())
	if live then
		creatureId = live:getId() or 0
	end

	local profile = memberProfileWire(target)

	-- Match ProtocolGame::sendBlessStatus: ignore Twist of Fate (id 1).
	-- 1 = grey (<5), 2 = gold (>=5), 3 = green (all 7 regular+enhanced).
	local blessCount = 0
	local blessings = {}
	for id = 1, 8 do
		local owned = false
		if target.hasBlessing and target:hasBlessing(id) then
			owned = true
		elseif target.getBlessingCount then
			local playerCount = tonumber(target:getBlessingCount(id)) or 0
			local storeCount = tonumber(target:getBlessingCount(id, true)) or 0
			owned = (playerCount + storeCount) >= 1
		end
		if owned then
			blessings[#blessings + 1] = id
			if id ~= 1 then
				blessCount = blessCount + 1
			end
		end
	end
	local blessVisualState = (blessCount >= 7) and 3 or ((blessCount >= 5) and 2 or 1)

	return {
		name = target:getName(),
		guid = target:getGuid(),
		level = profile.level,
		vocation = profile.vocation,
		online = wasOnline,
		creatureId = creatureId,
		equipment = equipment,
		backpack = bagItems,
		blessVisualState = blessVisualState,
		blessings = blessings,
	}
end

--- Bring a same-account member online (headless companion if needed) so their wheel can be opened/edited.
function TeamManager.ensureOnlineMember(controller, nameOrGuid)
	if not controller then
		return nil, "No player."
	end
	local member, err = TeamStore.resolveAccountMember(controller, nameOrGuid or controller:getName())
	if not member then
		return nil, err or "Unknown character."
	end
	local name = member:getName()
	local online = Player(name)
	if online then
		local ok, accErr = TeamManager.requireSameAccount(controller, online)
		if not ok then
			return nil, accErr
		end
		return online
	end
	return nil, "Character must be online for remote feature access."
end

--- Ensure online and return creature id for client g_game.openWheel.
function TeamManager.openWheel(controller, nameOrGuid)
	local target, err = TeamStore.resolveAccountMember(controller, nameOrGuid)
	if not target then
		return nil, err
	end
	if controller:getName():lower() == target:getName():lower() then
		return {
			name = target:getName(),
			guid = target:getGuid(),
			creatureId = controller:getId(),
		}
	end
	if not Game.deliverCompanionFeatureUI then
		return nil, "Companion feature control is unavailable."
	end
	if not Game.deliverCompanionFeatureUI(controller, target, "wheel") then
		return nil, "Failed to open Wheel of Destiny for that character."
	end
	return {
		name = target:getName(),
		guid = target:getGuid(),
		creatureId = 0,
	}
end

local function deliverCompanionFeatureOffline(controller, nameOrGuid, feature)
	local target, err = TeamStore.resolveAccountMember(controller, nameOrGuid)
	if not target then
		return nil, err
	end
	if controller:getName():lower() == target:getName():lower() then
		return nil, "Use local UI for your own character."
	end
	if not Game.deliverCompanionFeatureUI then
		return nil, "Companion feature control is unavailable."
	end
	if not Game.deliverCompanionFeatureUI(controller, target, feature) then
		return nil, string.format("Failed to open %s for that character.", feature)
	end
	return {
		name = target:getName(),
		guid = target:getGuid(),
		feature = feature,
	}
end

function TeamManager.openPrey(controller, nameOrGuid)
	return deliverCompanionFeatureOffline(controller, nameOrGuid, "prey")
end

function TeamManager.openForge(controller, nameOrGuid)
	return deliverCompanionFeatureOffline(controller, nameOrGuid, "forge")
end

function TeamManager.openProficiency(controller, nameOrGuid)
	return deliverCompanionFeatureOffline(controller, nameOrGuid, "proficiency")
end

function TeamManager.openRewardWall(controller, nameOrGuid)
	return deliverCompanionFeatureOffline(controller, nameOrGuid, "rewardWall")
end

function TeamManager.openTaskBoard(controller, nameOrGuid)
	return deliverCompanionFeatureOffline(controller, nameOrGuid, "taskBoard")
end

local function findItemByPath(player, msg)
	if type(msg) == "table" and msg.path then
		local item = resolveItemByPath(player, msg.path)
		if item then
			return item
		end
	end
	return nil
end

--- Resolve an item from OTC client inventory/container coordinates (x = 0xFFFF).
local function resolveClientPos(player, pos)
	if not player or type(pos) ~= "table" then
		return nil
	end
	local x = tonumber(pos.x) or 0
	local y = tonumber(pos.y) or 0
	local z = tonumber(pos.z) or 0
	if x ~= 65535 then
		return nil
	end
	-- Equipment: y is CONST_SLOT_* (1..10).
	if y >= CONST_SLOT_HEAD and y <= CONST_SLOT_AMMO then
		return player:getSlotItem(y)
	end
	-- Open container windows: y = containerId | 0x40, z = index (OTC encoding).
	if y >= 0x40 and player.getContainerById then
		local cid = y - 0x40
		local cont = player:getContainerById(cid)
		if cont and cont.getItem then
			return cont:getItem(z)
		end
	end
	return nil
end

--- Destination cylinder for a client pos (equip slot or open container).
local function resolveClientDest(player, pos)
	if not player or type(pos) ~= "table" then
		return nil, nil
	end
	local x = tonumber(pos.x) or 0
	local y = tonumber(pos.y) or 0
	local z = tonumber(pos.z) or 0
	if x ~= 65535 then
		return nil, nil
	end
	if y >= CONST_SLOT_HEAD and y <= CONST_SLOT_AMMO then
		return "slot", y
	end
	if y >= 0x40 and player.getContainerById then
		local cid = y - 0x40
		local cont = player:getContainerById(cid)
		if cont then
			return "container", cont
		end
	end
	return nil, nil
end

--- Offline loads + headless companions need an explicit save after inventory changes.
--- Note: Player:isOnline() is not exposed to Lua - never call it (was crashing moves).
local function saveIfOffline(player)
	if not player or not player.save or not player.getName then
		return
	end
	local live = Player(player:getName())
	if not live or isHeadlessCompanion(player) or (live and isHeadlessCompanion(live)) then
		player:save()
	end
end

--- Parent path for an open container that held an item (path without last index).
local function parentContainerPath(path)
	if type(path) ~= "table" then
		return nil
	end
	if path.rewardChest == true then
		local indices = path.indices
		if type(indices) ~= "table" or #indices == 0 then
			if path.rewardId ~= nil then
				return { rewardChest = true }
			end
			return nil
		end
		local parent = { rewardChest = true, rewardId = path.rewardId, indices = {} }
		for i = 1, #indices - 1 do
			parent.indices[i] = tonumber(indices[i]) or 0
		end
		if #parent.indices == 0 then
			parent.indices = nil
		end
		return parent
	end
	if path.lootPouch == true then
		local indices = path.indices
		if type(indices) ~= "table" or #indices == 0 then
			return nil
		end
		local parent = { lootPouch = true, indices = {} }
		for i = 1, #indices - 1 do
			parent.indices[i] = tonumber(indices[i]) or 0
		end
		if #parent.indices == 0 then
			parent.indices = nil
		end
		return parent
	end
	local slot = tonumber(path.slot) or 0
	if slot <= 0 then
		return nil
	end
	local indices = path.indices
	if type(indices) ~= "table" or #indices == 0 then
		-- Equipment slot alone (no bag nesting) - nothing to refresh as a container.
		return nil
	end
	local parent = { slot = slot, indices = {} }
	for i = 1, #indices - 1 do
		parent.indices[i] = tonumber(indices[i]) or 0
	end
	return parent
end

local function ensureBackpack(player)
	if not player then
		return nil
	end
	local bp = player:getSlotItem(CONST_SLOT_BACKPACK)
	if bp then
		return bp
	end
	-- addItem(itemId, count, canDropOnMap, subType, slot)
	pcall(function()
		player:addItem(2853, 1, false, 1, CONST_SLOT_BACKPACK)
	end)
	return player:getSlotItem(CONST_SLOT_BACKPACK)
end

--- Equip into a paperdoll slot. Occupied slots return NEEDEXCHANGE unless we free them first.
local function moveItemToEquipSlot(item, player, slot)
	if not item or not player or not slot then
		return false
	end
	slot = tonumber(slot)
	if not slot or slot < CONST_SLOT_HEAD or slot > CONST_SLOT_AMMO then
		return false
	end

	local existing = player:getSlotItem(slot)
	if existing and existing ~= item then
		if slot == CONST_SLOT_BACKPACK then
			-- Drop into the worn backpack instead of trying to swap/equip over it.
			if existing.getSize then
				return item:moveTo(existing) == true
			end
			return false
		end
		local bp = ensureBackpack(player)
		if not bp then
			return false
		end
		-- moveTo uses liberal flags so dump almost always succeeds for team admin moves.
		if not existing:moveTo(bp) then
			return false
		end
	end

	return item.moveToSlot and item:moveToSlot(player, slot) == true
end

local function resolveSourceItem(fromPlayer, msg)
	if type(msg.path) == "table" then
		local item = resolveItemByPath(fromPlayer, msg.path)
		if item then
			return item
		end
	end
	if type(msg.fromPos) == "table" then
		return resolveClientPos(fromPlayer, msg.fromPos)
	end
	return nil
end

--- Boss-reward (and other) owned items refuse moves to another character's containers.
--- Same-account team admin moves reassign ownership to the destination player.
local function transferOwnershipIfNeeded(item, toPlayer)
	if not item or not toPlayer then
		return
	end
	if not item.hasOwner or not item:hasOwner() then
		return
	end
	if item.isOwner and item:isOwner(toPlayer) then
		return
	end
	if item.setOwner then
		item:setOwner(toPlayer)
	elseif item.removeAttribute and ITEM_ATTRIBUTE_OWNER then
		item:removeAttribute(ITEM_ATTRIBUTE_OWNER)
	end
end

local REWARD_CONTAINER_ID = ITEM_REWARD_CONTAINER or 19202
local REWARD_CHEST_ITEM_ID = ITEM_REWARD_CHEST or 19250

--- Flatten nested ITEM_REWARD_CONTAINER bags (same as Player::getRewardsFromContainer).
local function flattenRewardItems(container, out)
	out = out or {}
	if not container or not container.getSize then
		return out
	end
	local size = container:getSize() or 0
	local snapshot = {}
	for i = 0, size - 1 do
		snapshot[#snapshot + 1] = container:getItem(i)
	end
	for _, it in ipairs(snapshot) do
		if it then
			local id = it.getId and it:getId() or 0
			if id == REWARD_CONTAINER_ID and it.getSize then
				flattenRewardItems(it, out)
			else
				out[#out + 1] = it
			end
		end
	end
	return out
end

--- Ensure reward bags have a parent cylinder so Item:moveTo can remove them.
--- Links parents only - does not open a chest window on the target's client.
local function prepareRewardChestParents(player)
	if not player then
		return
	end
	if player.linkRewardChestParents then
		pcall(function()
			player:linkRewardChestParents()
		end)
		return
	end
	-- Older builds: openRewardChest also wires parents (may push UI to target).
	if player.openRewardChest then
		pcall(function()
			player:openRewardChest()
		end)
	end
end

-- Inventory → map drop from the team UI (cursor tile). Cap range so crafted
-- opcodes cannot park items across the map via Item:moveTo's liberal defaults.
local GROUND_DROP_MAX_RANGE = 7

local function validateGroundDrop(controller, x, y, z)
	if not controller then
		return false, "Invalid destination."
	end
	local from = controller:getPosition()
	if not from then
		return false, "Invalid destination."
	end
	local dest = Position(x, y, z)
	local tile = Tile(dest)
	if not tile then
		return false, "Invalid destination."
	end
	if from.z ~= z then
		return false, "Too far."
	end
	local dist = math.max(math.abs(from.x - x), math.abs(from.y - y))
	if dist > GROUND_DROP_MAX_RANGE then
		return false, "Too far."
	end
	local instanceId = controller.getInstanceId and controller:getInstanceId() or 0
	if from.isSightClear and not from:isSightClear(dest, true, instanceId) then
		return false, "Cannot reach that tile."
	end
	return true
end

--- Move item between same-account characters (path, client pos, equip slot, bag destination).
function TeamManager.moveItem(controller, msg)
	msg = msg or {}
	local fromName = msg.fromName or msg.from
	local toName = msg.toName or msg.to
	if not fromName or not toName then
		return false, "fromName and toName required."
	end
	if not msg.path and not msg.fromPos and not msg.uid then
		return false, "path or fromPos required."
	end

	local fromPlayer, errFrom = TeamStore.resolveAccountMember(controller, fromName)
	if not fromPlayer then
		return false, errFrom
	end
	-- Offline load creates a fresh Player per call. Same-name must reuse one instance
	-- or moveToSlot targets a different inventory object than the source item.
	local toPlayer, errTo
	if tostring(fromName):lower() == tostring(toName):lower() then
		toPlayer = fromPlayer
	else
		toPlayer, errTo = TeamStore.resolveAccountMember(controller, toName)
		if not toPlayer then
			return false, errTo
		end
	end
	if not sameAccount(fromPlayer, toPlayer) or not sameAccount(controller, fromPlayer) then
		return false, "Characters must be on your account."
	end

	local item = resolveSourceItem(fromPlayer, msg)
	if not item then
		return false, "Item not found."
	end

	local count = tonumber(msg.count)
	if not count or count < 1 then
		count = item:getCount() or 1
	end

	local destSlot = tonumber(msg.toSlot)
	local moved = false
	local ownershipTransferred = false

	local function claimOwnership()
		if not ownershipTransferred then
			transferOwnershipIfNeeded(item, toPlayer)
			ownershipTransferred = true
		end
	end

	local function restoreOwnershipOnFail()
		if ownershipTransferred and fromPlayer ~= toPlayer then
			transferOwnershipIfNeeded(item, fromPlayer)
		end
	end

	if destSlot and destSlot >= CONST_SLOT_HEAD and destSlot <= CONST_SLOT_AMMO then
		claimOwnership()
		moved = moveItemToEquipSlot(item, toPlayer, destSlot)
	elseif type(msg.toPath) == "table" then
		if msg.toPath.rewardChest == true then
			return false, "Cannot move items into a reward chest."
		end
		-- Drop into a worn/open bag (path points at the container itself).
		local dest = resolveItemByPath(toPlayer, msg.toPath)
		if not dest or not dest.getSize then
			return false, "Destination container not found."
		end
		claimOwnership()
		moved = item:moveTo(dest)
	elseif type(msg.toPos) == "table" then
		local x = tonumber(msg.toPos.x) or 0
		local y = tonumber(msg.toPos.y) or 0
		local z = tonumber(msg.toPos.z) or 0
		if x ~= 65535 then
			-- Ground tile under the controller's map cursor (not inventory 0xFFFF coords).
			local okDrop, dropErr = validateGroundDrop(controller, x, y, z)
			if not okDrop then
				return false, dropErr or "Invalid destination."
			end
			-- No FLAG_NOLIMIT - engine distance/block checks still apply as a backstop.
			claimOwnership()
			moved = item:moveTo(Position(x, y, z), 0) == true
		else
			local kind, dest = resolveClientDest(toPlayer, msg.toPos)
			if kind == "slot" then
				claimOwnership()
				moved = moveItemToEquipSlot(item, toPlayer, dest)
			elseif kind == "container" then
				claimOwnership()
				moved = item:moveTo(dest)
			else
				return false, "Invalid destination."
			end
		end
	else
		local bp = ensureBackpack(toPlayer)
		if not bp then
			return false, "Target has no backpack."
		end
		claimOwnership()
		moved = item:moveTo(bp)
	end

	if not moved then
		restoreOwnershipOnFail()
		return false, "Could not move item."
	end

	saveIfOffline(fromPlayer)
	if toPlayer ~= fromPlayer then
		saveIfOffline(toPlayer)
	end
	return true
end

--- Paths of containers that should be re-sent after a move (source bag + dest bag).
function TeamManager.containerPathsToRefresh(msg)
	msg = msg or {}
	local paths = {}
	local function push(p)
		if type(p) ~= "table" then
			return
		end
		paths[#paths + 1] = copyPath(p)
	end
	if type(msg.containerPath) == "table" then
		push(msg.containerPath)
	elseif type(msg.path) == "table" then
		push(parentContainerPath(msg.path))
	end
	if type(msg.toPath) == "table" then
		push(msg.toPath)
	end
	return paths
end

function TeamManager.equipItem(controller, msg)
	msg = msg or {}
	msg.toSlot = tonumber(msg.slot or msg.toSlot)
	msg.toName = msg.name or msg.toName
	msg.fromName = msg.fromName or msg.toName
	if not msg.toSlot then
		return false, "slot required."
	end
	return TeamManager.moveItem(controller, msg)
end

--- Open a container on a same-account character (returns nested items for team UI).
function TeamManager.openContainer(controller, msg)
	msg = msg or {}
	local name = msg.name or msg.fromName
	local target, err = TeamStore.resolveAccountMember(controller, name)
	if not target then
		return nil, err
	end
	local ok, accErr = TeamManager.requireSameAccount(controller, target)
	if not ok then
		return nil, accErr
	end

	-- Path is preferred. equipSlot alone opens worn container (e.g. backpack slot).
	local path = copyPath(msg.path)
	if not path and msg.equipSlot then
		path = { slot = tonumber(msg.equipSlot) }
	end
	if not path and msg.slot then
		path = { slot = tonumber(msg.slot) }
	end

	if path and path.rewardChest == true and path.rewardId == nil then
		return TeamManager.openRewardChest(controller, name)
	end

	local item = path and resolveItemByPath(target, path) or nil
	if not item then
		if path and path.rewardChest == true then
			-- Vanished reward bag after collect - let the client close the window.
			return {
				name = target:getName(),
				guid = target:getGuid(),
				path = path,
				itemId = REWARD_CHEST_ITEM_ID,
				label = "Reward",
				items = {},
			}
		end
		return nil, "Container not found."
	end
	if not item.getSize then
		return nil, "Item is not a container."
	end
	local openPath = path or { slot = 0 }
	return {
		name = target:getName(),
		guid = target:getGuid(),
		path = openPath,
		itemId = item:getId(),
		label = item:getName() or "Container",
		items = containerWire(item, openPath, 100),
	}
end

--- Open boss reward chest for a same-account character (virtual team container).
function TeamManager.openRewardChest(controller, nameOrGuid)
	local target, err = TeamStore.resolveAccountMember(controller, nameOrGuid)
	if not target then
		return nil, err
	end
	local ok, accErr = TeamManager.requireSameAccount(controller, target)
	if not ok then
		return nil, accErr
	end
	if not target.getRewardList or not target.getReward then
		return nil, "Reward chest is unavailable."
	end

	local list = target:getRewardList()
	if type(list) ~= "table" then
		list = {}
	end

	local path = { rewardChest = true }
	local items = {}
	for _, rewardId in ipairs(list) do
		local reward = target:getReward(rewardId, false)
		if reward and reward ~= false and reward.getSize then
			local size = reward:getSize() or 0
			if size > 0 then
				local bagPath = { rewardChest = true, rewardId = rewardId }
				items[#items + 1] = itemWire(reward, bagPath)
			end
		end
	end

	-- Always return a container payload (possibly empty) so the client can close
	-- stale windows instead of showing "Reward chest is empty" error spam.
	return {
		name = target:getName(),
		guid = target:getGuid(),
		path = path,
		itemId = REWARD_CHEST_ITEM_ID,
		label = "Reward Chest",
		items = items,
	}
end

--- Move all items from a companion's reward bags into the controller's loot pouch.
function TeamManager.collectRewardChest(controller, nameOrGuid)
	if not controller then
		return nil, "No player."
	end
	local target, err = TeamStore.resolveAccountMember(controller, nameOrGuid)
	if not target then
		return nil, err
	end
	local ok, accErr = TeamManager.requireSameAccount(controller, target)
	if not ok then
		return nil, accErr
	end
	if not target.getRewardList or not target.getReward then
		return nil, "Reward chest is unavailable."
	end

	local destPouch = select(1, findLootPouch(controller))
	local destBp = ensureBackpack(controller)
	local dest = destPouch or destBp
	if not dest or not dest.getSize then
		return nil, "You have no loot pouch or backpack."
	end

	local list = target:getRewardList()
	if type(list) ~= "table" or #list == 0 then
		return nil, "Reward chest is empty."
	end

	-- Reward bags start without a parent; link parents for moves (no UI open).
	prepareRewardChestParents(target)

	local toMove = {}
	for _, rewardId in ipairs(list) do
		local reward = target:getReward(rewardId, false)
		if reward and reward ~= false then
			flattenRewardItems(reward, toMove)
		end
	end
	if #toMove == 0 then
		return nil, "Reward chest is empty."
	end

	local moved = 0
	local failed = 0
	for _, it in ipairs(toMove) do
		if it then
			transferOwnershipIfNeeded(it, controller)
			local okMove = false
			if it.moveTo then
				okMove = it:moveTo(dest) == true
				if not okMove and destBp and destBp ~= dest then
					okMove = it:moveTo(destBp) == true
				end
			end
			if okMove then
				moved = moved + 1
			else
				-- Leave unmoved items owned by the companion.
				transferOwnershipIfNeeded(it, target)
				failed = failed + 1
			end
		end
	end

	for _, rewardId in ipairs(list) do
		local reward = target:getReward(rewardId, false)
		if reward and reward ~= false and target.removeReward and reward.getSize and (reward:getSize() or 0) == 0 then
			target:removeReward(rewardId)
		end
	end

	saveIfOffline(target)
	saveIfOffline(controller)
	return {
		name = target:getName(),
		moved = moved,
		failed = failed,
	}
end

--- Open the loot pouch for a same-account character (store inbox or inventory).
function TeamManager.openLootPouch(controller, nameOrGuid)
	local target, err = TeamStore.resolveAccountMember(controller, nameOrGuid)
	if not target then
		return nil, err
	end
	local ok, accErr = TeamManager.requireSameAccount(controller, target)
	if not ok then
		return nil, accErr
	end
	local pouch, path = findLootPouch(target)
	if not pouch then
		return nil, "No loot pouch found."
	end
	if not pouch.getSize then
		return nil, "Loot pouch is not a container."
	end
	path = path or { lootPouch = true }
	return {
		name = target:getName(),
		guid = target:getGuid(),
		path = path,
		itemId = pouch:getId(),
		label = pouch:getName() or "Loot Pouch",
		items = containerWire(pouch, path, 100),
	}
end

--- Move every item from all team companions' loot pouches into the controller's pouch.
function TeamManager.pullAllLootPouches(controller)
	if not controller then
		return nil, "No player."
	end
	local destPouch = select(1, findLootPouch(controller))
	if not destPouch or not destPouch.getSize then
		return nil, "You have no loot pouch."
	end

	local controllerName = controller:getName()
	local names = TeamStore.getCompanionNames(controller)
	local moved = 0
	local failed = 0
	local sources = {}

	for _, name in ipairs(names) do
		if name and controllerName and name:lower() ~= controllerName:lower() then
			local member = TeamStore.resolveAccountMember(controller, name)
			if member then
				local srcPouch = select(1, findLootPouch(member))
				if srcPouch and srcPouch.getSize and srcPouch ~= destPouch then
					local size = srcPouch:getSize() or 0
					local memberMoved = 0
					local memberFailed = 0
					-- Walk backwards so removals do not shift pending indices.
					for i = size - 1, 0, -1 do
						local it = srcPouch:getItem(i)
						if it then
							if it.moveTo and it:moveTo(destPouch) then
								moved = moved + 1
								memberMoved = memberMoved + 1
							else
								failed = failed + 1
								memberFailed = memberFailed + 1
							end
						end
					end
					if memberMoved > 0 or memberFailed > 0 then
						sources[#sources + 1] = member:getName()
					end
					saveIfOffline(member)
				end
			end
		end
	end

	saveIfOffline(controller)
	return {
		moved = moved,
		failed = failed,
		sources = sources,
	}
end

--- Load automation config for a same-account team member.
function TeamManager.getAutomation(controller, nameOrGuid)
	local target, err = TeamStore.resolveAccountMember(controller, nameOrGuid)
	if not target then
		return nil, err
	end
	local ok, accErr = TeamManager.requireSameAccount(controller, target)
	if not ok then
		return nil, accErr
	end
	if not CombatAutomationStore or not CombatAutomationStore.getConfig then
		return nil, "Combat automation is not available."
	end
	-- Prefer load for offline characters so we do not attach a runtime loop / share id=0 state.
	local online = Player(target:getName())
	local config
	if online and CombatAutomationStore.getConfig then
		config = CombatAutomationStore.getConfig(online)
	else
		config = CombatAutomationStore.load(target)
	end
	local profile = memberProfileWire(target)
	return {
		name = target:getName(),
		guid = target:getGuid(),
		level = profile.level,
		vocation = profile.vocation,
		autoTarget = config.autoTarget or { enabled = false, stance = "melee", rangedDistance = 3 },
		ammoTypeId = math.floor(tonumber(config.ammoTypeId) or 0),
		loadout = {
			slots = config.slots or {},
			ammoTypeId = math.floor(tonumber(config.ammoTypeId) or 0),
		},
	}
end

--- Persist automation config for a same-account team member (live headless gets runtime apply).
function TeamManager.setAutomation(controller, msg)
	msg = msg or {}
	local name = msg.name or msg.character or msg.target
	local target, err = TeamStore.resolveAccountMember(controller, name)
	if not target then
		return nil, err
	end
	local ok, accErr = TeamManager.requireSameAccount(controller, target)
	if not ok then
		return nil, accErr
	end
	if not CombatAutomationStore then
		return nil, "Combat automation is not available."
	end

	local raw = {
		loadout = msg.loadout,
		slots = msg.slots,
		autoTarget = msg.autoTarget,
		ammoTypeId = msg.ammoTypeId,
	}
	if type(msg.loadout) == "table" then
		if msg.loadout.slots then
			raw.slots = msg.loadout.slots
		end
		if raw.ammoTypeId == nil then
			raw.ammoTypeId = msg.loadout.ammoTypeId
		end
	end

	local config
	local online = Player(target:getName())
	if online then
		-- Online or headless companion: full setConfig + runtime loop.
		config = CombatAutomationStore.setConfig(online, raw)
		saveIfOffline(online)
	else
		-- Offline character: persist KV only (no combat tick loop).
		config = CombatAutomationStore.sanitize(raw, target)
		CombatAutomationStore.persist(target, config)
		if target.save then
			target:save()
		end
	end

	local profile = memberProfileWire(target)
	return {
		name = target:getName(),
		guid = target:getGuid(),
		level = profile.level,
		vocation = profile.vocation,
		autoTarget = config.autoTarget or { enabled = false, stance = "melee", rangedDistance = 3 },
		ammoTypeId = math.floor(tonumber(config.ammoTypeId) or 0),
		loadout = {
			slots = config.slots or {},
			ammoTypeId = math.floor(tonumber(config.ammoTypeId) or 0),
		},
	}
end

--- Ensure headless companion API presence (async batch + logout).
function TeamManager.hasCompanionApi()
	return type(Game.headlessLoginBatch) == "function" and type(Game.headlessLogout) == "function"
end
