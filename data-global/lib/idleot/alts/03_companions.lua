-- Headless companions: marking, party wiring, deploy (headless login) and undeploy.
Alts = Alts or {}

-- primaryGuid -> { companionIds = {playerId, ...}, partyOwned = bool }
local deployments = {}
-- accountId -> number of deploys still headless-loading companions
local deployLoadsByAccount = {}

local function isHeadlessCompanion(player)
	if not player then
		return false
	end
	local ctrl = player:getStorageValue(AltsConfig.STORAGE_COMPANION_CONTROLLER)
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
	companion:setStorageValue(AltsConfig.STORAGE_COMPANION_CONTROLLER, controller:getGuid())
end

local function clearCompanionMark(companion)
	if companion then
		companion:setStorageValue(AltsConfig.STORAGE_COMPANION_CONTROLLER, -1)
	end
end

function Alts.isCompanion(player)
	return isHeadlessCompanion(player)
end

function Alts.isRealUiClient(player)
	return isRealUiClient(player)
end

--- True when guid has a live ProtocolGame UI (not headless / protocol 0 / companion).
function Alts.isRealOnlineClient(guid)
	local online = Alts.findOnlinePlayerByGuid(guid)
	return online ~= nil and isRealUiClient(online)
end

function Alts.markCompanion(companion, controller)
	markCompanion(companion, controller)
end

function Alts.clearCompanionMark(companion)
	clearCompanionMark(companion)
end

function Alts.getCompanionController(companion)
	if not companion or not isHeadlessCompanion(companion) then
		return nil
	end
	local guid = companion:getStorageValue(AltsConfig.STORAGE_COMPANION_CONTROLLER)
	if not guid or guid <= 0 then
		return nil
	end
	return Alts.findOnlinePlayerByGuid(guid)
end

--- Steal/reform party so controller is leader. force=true allows taking from a live UI host.
local function takePartyLeadership(controller, party, force)
	if not controller or not party then
		return nil, false, false
	end
	local leader = party:getLeader()
	if leader and leader:getId() == controller:getId() then
		return party, false, true
	end
	local leaderIsAbandonedHeadless = leader and Alts.sameAccount(leader, controller) and not isRealUiClient(leader)
	if not force and not leaderIsAbandonedHeadless then
		return nil, false, false
	end
	logger.info(
		"[Alts] {} taking party leadership from {} (force={})",
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

local function isInParty(party, player)
	local leader = party:getLeader()
	if leader and leader:getId() == player:getId() then
		return true
	end
	for _, m in ipairs(party:getMembers() or {}) do
		if m and m:getId() == player:getId() then
			return true
		end
	end
	return false
end

--- Ensure controller leads a party that includes all companions.
--- opts.force: take leadership even from a real-UI same-account leader.
--- Returns party, partyOwned, errMessage
function Alts.ensureControllerParty(controller, companions, opts)
	companions = companions or {}
	opts = opts or {}
	local party = controller:getParty()
	local partyOwned = false

	if party then
		local leader = party:getLeader()
		if not leader or leader:getId() ~= controller:getId() then
			local newParty, owned, ok = takePartyLeadership(controller, party, opts.force == true)
			if not ok then
				return nil, false, "Only the party leader can deploy alts."
			end
			party = newParty
			partyOwned = owned
			if not party then
				return nil, false, "Failed to create party."
			end
		end
	elseif #companions > 0 then
		party = Party(controller)
		if not party then
			return nil, false, "Failed to create party."
		end
		partyOwned = true
	end

	if not party then
		return nil, false, nil
	end

	for _, companion in ipairs(companions) do
		if companion and companion.getId and not isInParty(party, companion) then
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
					"[Alts] {} failed to party-join companion {} (invite={} joined={}); expedition will still pull them via deploy list",
					controller:getName(),
					companion:getName(),
					tostring(invited),
					tostring(joined)
				)
			end
		end
	end
	if party.setSharedExperience then
		party:setSharedExperience(true)
	end
	return party, partyOwned, nil
end

--- Leave / disband member's current party, then force-join host party.
function Alts.forceJoinToParty(host, member)
	if not host or not member then
		return false, "Invalid request."
	end
	if host:getId() == member:getId() then
		return false, "Cannot join yourself."
	end

	local old = member:getParty()
	if old then
		local leader = old:getLeader()
		local others = 0
		for _, m in ipairs(old:getMembers() or {}) do
			if m and m:getId() ~= member:getId() then
				others = others + 1
			end
		end
		if leader and leader:getId() == member:getId() and others == 0 then
			pcall(function()
				old:disband()
			end)
		else
			pcall(function()
				old:removeMember(member)
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

	if isInParty(party, member) then
		return true
	end

	party:addInvite(member)
	local joined = party:addMember(member)
	if not joined then
		pcall(function()
			party:addInvite(member)
			joined = party:addMember(member)
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

-- Lua onDeath precedes C++ death penalties; wait for HP restore before save+logout.
local COMPANION_LOGOUT_DEFER_MS = 350
local COMPANION_LOGOUT_MAX_WAIT_MS = 3000
local COMPANION_LOGOUT_POLL_MS = 100
-- playerId -> generation; bumping cancels an in-flight deferred logout (switch redeploy).
local pendingCompanionLogoutGen = {}

local function parkCompanionBeforeLogout(companion)
	if not companion then
		return
	end
	local pos = companion.getPosition and companion:getPosition() or nil
	local needPark = Instance.isPrivate(Instance.of(companion))
	if not needPark and ExpeditionConfig and companion.getStorageValue and companion:getStorageValue(ExpeditionConfig.STORAGE_ACTIVE) == 1 then
		needPark = true
	end
	if not needPark and pos and InstanceWorld and InstanceWorld.classify then
		local kind = InstanceWorld.classify(pos).kind
		if kind == "hunt" or kind == "blocked" then
			needPark = true
		end
	end
	if not needPark then
		return
	end
	-- Persist open-world loginPosition: C++ logout saves getPosition().
	local returnPos = ExpeditionManager and ExpeditionManager.loadReturnPos and ExpeditionManager.loadReturnPos(companion) or nil
	if InstanceWorld and InstanceWorld.exitToOpenWorld then
		pcall(InstanceWorld.exitToOpenWorld, companion, returnPos)
	elseif returnPos and companion.teleportTo then
		pcall(function()
			companion:teleportTo(returnPos)
		end)
	end
end

local function safeLogoutCompanion(companion, deferMs)
	if not companion or not isHeadlessCompanion(companion) then
		return
	end
	local playerId = companion:getId()
	local startedMs = CombatGeo.nowMs()
	local gen = (pendingCompanionLogoutGen[playerId] or 0) + 1
	pendingCompanionLogoutGen[playerId] = gen

	local function logoutNow()
		local c = Player(playerId)
		if not c or not isHeadlessCompanion(c) then
			return
		end
		-- Exercise training keeps the body until the weapons run out; sendPing removes it then.
		if c.isTraining and c:isTraining() ~= 0 then
			return
		end
		parkCompanionBeforeLogout(c)
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
		if hp <= 0 and (CombatGeo.nowMs() - startedMs) < COMPANION_LOGOUT_MAX_WAIT_MS then
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

function Alts.safeLogoutCompanion(companion, deferMs)
	safeLogoutCompanion(companion, deferMs)
end

--- Cancel a deferred companion logout (e.g. leave->switch redeploy reused the same creature).
function Alts.cancelCompanionLogout(companionOrId)
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

function Alts.getDeployment(controller)
	if not controller then
		return nil
	end
	return deployments[controller:getGuid()]
end

--- Move deployment bookkeeping when the controlling character changes (alt switch / handoff).
function Alts.transferDeployment(oldGuid, newGuid)
	oldGuid = tonumber(oldGuid) or 0
	newGuid = tonumber(newGuid) or 0
	if oldGuid <= 0 or newGuid <= 0 or oldGuid == newGuid then
		return
	end
	if deployments[oldGuid] then
		deployments[newGuid] = deployments[oldGuid]
		deployments[oldGuid] = nil
	end
end

function Alts.isDeploying(accountId)
	return (deployLoadsByAccount[tonumber(accountId) or 0] or 0) > 0
end

--- Companion names the controller would deploy. The lobby installs the provider.
function Alts.companionNamesFor(controller)
	if type(Alts.companionNamesProvider) == "function" then
		local ok, names = pcall(Alts.companionNamesProvider, controller)
		if ok and type(names) == "table" then
			return names
		end
	end
	return {}
end

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
local function finalizeDeploy(controller, companions)
	local party, partyOwned, partyErr = Alts.ensureControllerParty(controller, companions)
	if partyErr then
		for _, c in ipairs(companions) do
			if isHeadlessCompanion(c) then
				clearCompanionMark(c)
				Game.headlessLogout(c)
			end
		end
		return nil, partyErr
	end

	local ids = {}
	for _, c in ipairs(companions) do
		ids[#ids + 1] = c:getId()
	end
	if #ids > 0 or (partyOwned and party) then
		deployments[controller:getGuid()] = {
			companionIds = ids,
			partyOwned = partyOwned,
		}
	end

	logger.info("[Alts] {} deployed {} companion(s)", controller:getName(), #companions)
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

local function placeAt(creature, spawnPos, opts)
	if opts.position then
		if opts.instanceId then
			creature:teleportTo(spawnPos, false, opts.instanceId)
		else
			creature:teleportTo(spawnPos)
		end
	elseif opts.instanceId then
		logger.warn("[Alts] refusing same-tile instance rebind for {} (pass opts.position)", creature:getName())
	end
end

local function claimOnlineCompanion(controller, online, spawnPos, opts)
	if online.getHealth and online:getHealth() <= 0 then
		safeLogoutCompanion(online)
		return nil
	end
	Alts.cancelCompanionLogout(online)
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
	placeAt(online, spawnPos, opts)
	markCompanion(online, controller)
	if online.setHeadless then
		online:setHeadless(true)
	end
	logger.info("[Alts] {} claimed headless {} as companion", controller:getName(), online:getName())
	return online
end

local function acceptLoadedCompanions(controller, companions, loaded, accountId)
	for _, companion in ipairs(loaded or {}) do
		if not companion then
			rollbackCompanions(companions)
			return nil, "Failed to log in alt."
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

--- Deploy account companions near the controller. All-or-nothing: if any requested
--- companion cannot come (e.g. it is on a real client), none are deployed.
--- opts.names: companion names (default Alts.companionNamesFor(controller)).
--- opts.position: spawn/teleport companions here (e.g. lobby tile / expedition entry).
--- opts.instanceId: bind private instance id before place (atomic with headlessLogin).
--- opts.onComplete = function(companions|nil, err|nil) - required; DB loads are async.
function Alts.deploy(controller, opts)
	opts = opts or {}
	if not controller then
		return deliverDeployResult(opts, nil, "No player.")
	end
	if type(opts.onComplete) ~= "function" then
		return deliverDeployResult(opts, nil, "Alt deploy requires async onComplete.")
	end
	if not Game.headlessLoginBatch then
		return deliverDeployResult(opts, nil, "Headless login batch is not available on this server build.")
	end

	local spawnPos = opts.position or controller:getPosition()
	local instanceId = Instance.normalize(opts.instanceId)
	local accountId = controller:getAccountId()
	local names = type(opts.names) == "table" and opts.names or Alts.companionNamesFor(controller)

	for _, name in ipairs(names) do
		local online = Player(name)
		if online and online:getId() ~= controller:getId() and isRealUiClient(online) then
			return deliverDeployResult(opts, nil, string.format("%s is online on a real client.", online:getName()))
		end
	end

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
					Alts.cancelCompanionLogout(p)
					placeAt(p, spawnPos, opts)
					live[#live + 1] = p
					liveByName[p:getName():lower()] = true
				end
			end
		end
		for _, name in ipairs(names) do
			if not liveByName[name:lower()] then
				local online = Player(name)
				if not (online and isRealUiClient(online)) then
					deployments[controller:getGuid()] = nil
					return Alts.deploy(controller, opts)
				end
			end
		end
		local _, _, partyErr = Alts.ensureControllerParty(controller, live)
		if partyErr then
			return deliverDeployResult(opts, nil, partyErr)
		end
		for _, p in ipairs(live) do
			applyCompanionAutoRebuy(p)
		end
		return deliverDeployResult(opts, live, nil)
	end

	local companions = {}
	local namesToLoad = {}
	for _, name in ipairs(names) do
		if name:lower() ~= controller:getName():lower() then
			local online = Player(name)
			if online and online.getId and online:getId() == controller:getId() then
				-- Deployer listed as companion (stale) - ignore.
			elseif online then
				local claimed = claimOnlineCompanion(controller, online, spawnPos, opts)
				if claimed then
					companions[#companions + 1] = claimed
				else
					namesToLoad[#namesToLoad + 1] = name
				end
			else
				-- Existence + account are checked off-thread by headlessLoginBatch before place.
				namesToLoad[#namesToLoad + 1] = name
			end
		end
	end

	if #namesToLoad == 0 then
		local finalized, ferr = finalizeDeploy(controller, companions)
		return deliverDeployResult(opts, finalized, ferr)
	end

	local claimed = companions
	deployLoadsByAccount[accountId] = (deployLoadsByAccount[accountId] or 0) + 1
	Game.headlessLoginBatch(namesToLoad, spawnPos, function(loaded, loadErr)
		local pendingLoads = (deployLoadsByAccount[accountId] or 1) - 1
		deployLoadsByAccount[accountId] = pendingLoads > 0 and pendingLoads or nil
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
			opts.onComplete(nil, loadErr or "Failed to log in alts.")
			return
		end
		local merged, mergeErr = acceptLoadedCompanions(controller, claimed, loaded, accountId)
		if not merged then
			opts.onComplete(nil, mergeErr)
			return
		end
		local finalized, ferr = finalizeDeploy(controller, merged)
		opts.onComplete(finalized, ferr)
	end, instanceId, accountId)
	return true
end

function Alts.undeploy(controller, opts)
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
				-- headlessLogout -> removeCreature -> onRemoveCreature leaveParty (force).
				-- Avoid party:removeMember first; double leave/disband can desync map sectors.
				if opts.returnPos then
					pcall(function()
						companion:teleportTo(opts.returnPos)
					end)
				end
				-- Voluntary undeploy: logout immediately so leave->switch cannot redeploy
				-- the same creature and then hit a deferred logout as a false hunt death.
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
	logger.info("[Alts] {} undeployed companions", controller:getName())
end

--- Online same-account member whose wheel the controller may open/edit.
function Alts.ensureOnlineMember(controller, nameOrGuid)
	if not controller then
		return nil, "No player."
	end
	local member, err = Alts.resolveAccountMember(controller, nameOrGuid or controller:getName())
	if not member then
		return nil, err or "Unknown character."
	end
	local online = Player(member:getName())
	if online then
		local ok, accErr = Alts.requireSameAccount(controller, online)
		if not ok then
			return nil, accErr
		end
		return online
	end
	return nil, "Character must be online for remote feature access."
end
