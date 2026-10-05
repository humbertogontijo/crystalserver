-- Alt switching: move the live client onto another same-account character.
Alts = Alts or {}

-- accountId -> last switch ms
local lastAltSwitchByAccount = {}

local function vocationNameById(vocationId)
	local ok, name = pcall(function()
		local vocation = Vocation(tonumber(vocationId) or 0)
		return vocation and vocation:getName() or ""
	end)
	return ok and type(name) == "string" and name or ""
end

local function isInHunt(player)
	if not (ExpeditionManager and ExpeditionManager.getSessionByPlayer) then
		return false
	end
	local ok, session = pcall(ExpeditionManager.getSessionByPlayer, player)
	return ok and session ~= nil
end

local function countAccountOnline(accountId)
	local count = 0
	for _, online in ipairs(Game.getPlayers()) do
		if online:getAccountId() == accountId then
			count = count + 1
		end
	end
	return count
end

local function sendError(player, message)
	if type(Alts.errorSink) == "function" then
		pcall(Alts.errorSink, player, message)
	elseif player then
		player:sendTextMessage(MESSAGE_FAILURE, tostring(message))
	end
end

--- Every character on the player's account with live status for the alt switcher.
function Alts.getAccountAlts(player)
	local alts = {}
	local accountId = player and player:getAccountId() or 0
	if accountId <= 0 then
		return alts
	end
	local resultId = db.storeQuery(
		"SELECT `id`, `name`, `level`, `vocation`, `looktype`, `lookhead`, `lookbody`, `looklegs`, `lookfeet`, `lookaddons` FROM `players` WHERE `account_id` = "
			.. tonumber(accountId)
			.. " AND `deletion` = 0 ORDER BY `name` ASC"
	)
	if not resultId then
		return alts
	end
	repeat
		local name = Result.getString(resultId, "name")
		local entry = {
			name = name,
			guid = Result.getNumber(resultId, "id"),
			level = Result.getNumber(resultId, "level"),
			vocation = vocationNameById(Result.getNumber(resultId, "vocation")),
			outfit = {
				type = Result.getNumber(resultId, "looktype"),
				head = Result.getNumber(resultId, "lookhead"),
				body = Result.getNumber(resultId, "lookbody"),
				legs = Result.getNumber(resultId, "looklegs"),
				feet = Result.getNumber(resultId, "lookfeet"),
				addons = Result.getNumber(resultId, "lookaddons"),
			},
			online = false,
			playing = false,
			inHunt = false,
		}
		local online = Player(name)
		if online then
			local profile = Alts.memberProfile(online)
			entry.online = true
			entry.playing = online:getId() == player:getId()
			entry.level = profile.level
			entry.vocation = profile.vocation
			entry.outfit = profile.outfit or entry.outfit
			entry.inHunt = isInHunt(online)
		end
		alts[#alts + 1] = entry
	until not Result.next(resultId)
	Result.free(resultId)
	return alts
end

local function performAltSwitch(playerId, targetId)
	local player = Player(playerId)
	local target = Player(targetId)
	if not player or not target then
		return
	end
	if not player:switchClientTo(target) then
		sendError(player, "Could not switch to " .. target:getName() .. ".")
		return
	end
	logger.info("[Alts] client switched {} -> {}", player:getName(), target:getName())
	if ExpeditionManager and ExpeditionManager.onClientSwitched then
		local ok, err = pcall(ExpeditionManager.onClientSwitched, player, target)
		if not ok then
			logger.error("[Alts] expedition handoff failed {} -> {}: {}", player:getName(), target:getName(), err)
		end
	end
end

--- Validate and start an alt switch. Offline alts are loaded headless first.
function Alts.switchAlt(player, targetName)
	if not player then
		return false, "No player."
	end
	if player:getHealth() <= 0 then
		return false, "You cannot switch while dead."
	end
	local name = tostring(targetName or "")
	if name == "" then
		return false, "Choose an alt."
	end
	if name:lower() == player:getName():lower() then
		return false, "You are already playing that character."
	end
	local target, err = Alts.resolveAccountMember(player, name)
	if not target then
		return false, err or "Unknown character."
	end
	local accountId = player:getAccountId()
	-- The deploy callback hands companions to the controller it started with; switching
	-- before it lands would split the deployment from the new lobby host.
	if Alts.isDeploying(accountId) then
		return false, "Your alts are still deploying, try again in a moment."
	end
	local now = CombatGeo.nowMs()
	local cooldown = AltsConfig.ALT_SWITCH_COOLDOWN_MS or 2000
	if now - (lastAltSwitchByAccount[accountId] or 0) < cooldown then
		return false, "Please wait a moment before switching again."
	end

	local resolvedName = target:getName()
	local playerId = player:getId()
	local online = Player(resolvedName)
	if online then
		if online:getHealth() <= 0 then
			return false, resolvedName .. " is dead."
		end
		lastAltSwitchByAccount[accountId] = now
		addEvent(performAltSwitch, 0, playerId, online:getId())
		return true
	end

	local maxOnline = configManager.getNumber(configKeys.MAX_PLAYERS_PER_ACCOUNT) or 0
	if maxOnline > 0 and player:getAccountType() < ACCOUNT_TYPE_GAMEMASTER then
		local onlineCount = countAccountOnline(accountId)
		-- Same slot math as logout + login: the body we leave frees its slot unless it stays
		-- online (hunt handoff turns it into a headless companion, idle combat, VIP stay).
		if not isInHunt(player) and player:leavesWhenClientReleased() then
			onlineCount = onlineCount - 1
		end
		if onlineCount >= maxOnline then
			return false, string.format("You may only have %d characters of your account online at the same time.", maxOnline)
		end
	end

	lastAltSwitchByAccount[accountId] = now
	Game.headlessLoginBatch({ resolvedName }, nil, function(players, loginErr)
		local live = Player(playerId)
		if not live then
			return
		end
		local loaded = type(players) == "table" and players[1] or nil
		if not loaded then
			sendError(live, loginErr or ("Could not load " .. resolvedName .. "."))
			return
		end
		performAltSwitch(playerId, loaded:getId())
	end)
	return true
end
