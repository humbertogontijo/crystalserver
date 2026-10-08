-- Lobby start: call members outside the room, gather (alts log in headless inside the
-- room), then the whole room channels into the expedition (ExpeditionManager.join scope "lobby").
-- Any decline, timeout, logout or member removal during the call cancels for everyone.
LobbyStart = LobbyStart or {}

-- Pause after alts arrive so everyone sees them before the expedition channel.
LobbyStart.GATHER_PAUSE_MS = 1000

local nextToken = 1

local function online(guid)
	return Alts.findOnlinePlayerByGuid(guid)
end

local function broadcast(record)
	if record then
		LobbyProtocol.broadcast(record)
	end
end

local function tellHumans(record, message)
	for _, p in ipairs(LobbyManager.onlineHumans(record)) do
		p:sendTextMessage(MESSAGE_EVENT_ADVANCE, message)
	end
end

function LobbyStart.isActive(record)
	if not record then
		return false
	end
	local rt = LobbyStore.runtime(record)
	return rt.call ~= nil or rt.channeling ~= nil
end

--- Cancel the call / gather for everyone. Alts already deployed for it log out.
function LobbyStart.cancel(record, reason)
	if not record then
		return
	end
	local rt = LobbyStore.runtime(record)
	local call, channeling = rt.call, rt.channeling
	if not call and not channeling then
		return
	end
	rt.call = nil
	rt.channeling = nil
	if call then
		if call.event then
			stopEvent(call.event)
		end
		for guid in pairs(call.accepted or {}) do
			local p = online(guid)
			if p and InstanceTeleport.isPending(p) then
				InstanceTeleport.cancel(p)
			end
		end
		for guid in pairs(call.pending or {}) do
			local p = online(guid)
			if p then
				LobbyProtocol.send(p, { type = "callCleared", lobbyId = record.id })
			end
		end
	end
	if channeling then
		local host = online(record.hostGuid)
		if host and Alts.getDeployment(host) and not ExpeditionManager.getSessionByPlayer(host) then
			Alts.undeploy(host)
		end
	end
	tellHumans(record, tostring(reason or "The lobby start was cancelled."))
	broadcast(record)
end

--- Host aborts a call or gather before the expedition channel starts.
function LobbyStart.hostCancel(player)
	local record = LobbyStore.getForPlayer(player)
	if not record or record.hostGuid ~= player:getGuid() then
		return false, "Only the lobby host can cancel the start."
	end
	if not LobbyStart.isActive(record) then
		return false, "The lobby is not starting."
	end
	LobbyStart.cancel(record, string.format("Lobby start cancelled by %s.", player:getName()))
	return true
end

local function isSoloOnly(catalog)
	if catalog.role == "arena" then
		return true
	end
	local isBoss = catalog.role == "boss" or catalog.kind == "boss"
	return isBoss and ExpeditionConfig.isSoloBoss and ExpeditionConfig.isSoloBoss(catalog) or false
end

--- Boss cooldown blocking the lobby expedition: remainingSec, blockerName (0, nil when clear).
--- Solo bosses only check the host; lever bosses every online member, alts included (offline
--- alts are checked by the expedition entry once deployed).
function LobbyStart.bossCooldown(record)
	if not record or record.role ~= "boss" then
		return 0, nil
	end
	local catalog = ExpeditionConfig.getById(record.expeditionId, "boss")
	local bossName = catalog and ExpeditionConfig.bossTypeName(catalog)
	if not bossName then
		return 0, nil
	end
	local fighters
	if isSoloOnly(catalog) then
		fighters = { online(record.hostGuid) }
	else
		fighters = LobbyManager.onlineHumans(record)
		for _, alt in ipairs(LobbyStore.alts(record)) do
			local player = online(alt.guid)
			if player then
				fighters[#fighters + 1] = player
			end
		end
	end
	local remaining, blocker = ExpeditionConfig.partyBossCooldown(fighters, bossName)
	if remaining <= 0 then
		return 0, nil
	end
	return remaining, blocker:getName()
end

--- Error naming the humans below the expedition level (nil when everyone may enter).
local function levelError(record, catalog)
	local levelMin = catalog.levelMin or 1
	local fighters = isSoloOnly(catalog) and { online(record.hostGuid) } or LobbyManager.onlineHumans(record)
	local blocked = ExpeditionManager.underleveled(fighters, levelMin)
	if #blocked == 0 then
		return nil
	end
	local names = {}
	for _, p in ipairs(blocked) do
		names[#names + 1] = string.format("%s (%d)", p:getName(), p:getLevel())
	end
	return string.format("%s requires level %d: %s.", catalog.name, levelMin, table.concat(names, ", "))
end

local function launch(lobbyId, token)
	local record = LobbyStore.get(lobbyId)
	if not record then
		return
	end
	local rt = LobbyStore.runtime(record)
	if rt.channeling ~= token then
		return
	end
	rt.channeling = nil
	local host = online(record.hostGuid)
	if not host then
		LobbyStart.cancel(record, "The lobby host went offline.")
		return
	end
	ExpeditionManager.join(host, record.expeditionId, record.role, rt.loadout, nil, {
		scope = "lobby",
		lobbyId = record.id,
		bossDifficulty = record.bossDifficulty,
	})
	if not ExpeditionManager.getSessionByPlayer(host) and Alts.getDeployment(host) then
		-- Join refused (level, cooldown, stamina...): alts do not wait in the room.
		Alts.undeploy(host)
	end
	broadcast(record)
end

--- Everyone is inside: log alts in on the room tiles, then launch.
function LobbyStart.gather(record)
	local rt = LobbyStore.runtime(record)
	rt.call = nil
	local host = online(record.hostGuid)
	if not host then
		broadcast(record)
		return false, "The lobby host is offline."
	end
	local room, err = LobbyInstance.ensureRoom(record)
	if not room then
		broadcast(record)
		return false, err
	end
	local token = nextToken
	nextToken = nextToken + 1
	rt.channeling = token
	LobbyInstance.arrange(record)
	broadcast(record)

	local catalog = ExpeditionConfig.getById(record.expeditionId, record.role)
	local names = LobbyStore.altNames(record)
	if #names == 0 or not catalog or isSoloOnly(catalog) then
		launch(record.id, token)
		return true
	end

	local lobbyId = record.id
	Alts.deploy(host, {
		names = names,
		position = LobbyInstance.spawnPosition(room),
		instanceId = room.instanceId,
		onComplete = function(alts, deployErr)
			local live = LobbyStore.get(lobbyId)
			if not live or LobbyStore.runtime(live).channeling ~= token then
				return
			end
			if not alts then
				LobbyStart.cancel(live, deployErr or "Failed to log in the lobby alts.")
				return
			end
			for _, alt in ipairs(alts) do
				if not LobbyInstance.isInRoom(alt, live) then
					LobbyInstance.enterNow(alt, live, {})
				else
					InstanceTeleport.sendArrivalEffect(alt, InstanceTeleport.KIND_LOBBY)
				end
			end
			LobbyInstance.arrange(live)
			broadcast(live)
			addEvent(launch, LobbyStart.GATHER_PAUSE_MS, lobbyId, token)
		end,
	})
	return true
end

local function onTimeout(lobbyId, token)
	local record = LobbyStore.get(lobbyId)
	local call = record and LobbyStore.runtime(record).call
	if not call or call.token ~= token then
		return
	end
	call.event = nil
	local missing = {}
	for _, name in pairs(call.pending) do
		missing[#missing + 1] = name
	end
	table.sort(missing)
	LobbyStart.cancel(record, "Lobby start cancelled: " .. table.concat(missing, ", ") .. " did not arrive in time.")
end

--- Host pressed Start. msg.loadout is the host's automation loadout for the run.
function LobbyStart.request(player, msg)
	local record = LobbyStore.getForPlayer(player)
	if not record then
		return false, "You are not in a lobby."
	end
	if record.hostGuid ~= player:getGuid() then
		return false, "Only the lobby host can start."
	end
	if record.expeditionId == "" then
		return false, "Choose an expedition for the lobby first."
	end
	if not LobbyManager.isIdle(record) then
		return false, "The lobby is already starting or running an expedition."
	end
	if ExpeditionManager.getSessionByPlayer(player) then
		return false, "Leave your current expedition first."
	end
	local catalog = ExpeditionConfig.getById(record.expeditionId, record.role)
	if not catalog then
		return false, "Unknown expedition."
	end
	local levelErr = levelError(record, catalog)
	if levelErr then
		return false, levelErr
	end
	if LobbyStart.bossCooldown(record) > 0 then
		-- No message: the lobby card shows the cooldown timer; resync a stale client.
		LobbyProtocol.broadcast(record)
		return false, nil
	end
	local rt = LobbyStore.runtime(record)
	rt.loadout = type(msg) == "table" and msg.loadout or nil

	-- Host outside the room: channel in first; the call (if anyone is still missing)
	-- only starts once the host has arrived.
	if not LobbyInstance.isInRoom(player, record) then
		local lobbyId = record.id
		local ok, err = InstanceTeleport.requestLobby(player, record, {
			onComplete = function(p, entered, enterErr)
				if not entered then
					if enterErr then
						p:sendTextMessage(MESSAGE_FAILURE, enterErr)
					end
					return
				end
				local live = LobbyStore.get(lobbyId)
				if not live or live.hostGuid ~= p:getGuid() then
					return
				end
				local started, startErr = LobbyStart.request(p, msg)
				if not started and startErr then
					p:sendTextMessage(MESSAGE_FAILURE, startErr)
				end
			end,
		})
		if not ok then
			return false, err
		end
		return true
	end

	local pending = {}
	local outside = 0
	for _, p in ipairs(LobbyManager.onlineHumans(record)) do
		if not LobbyInstance.isInRoom(p, record) then
			pending[p:getGuid()] = p:getName()
			outside = outside + 1
		end
	end
	if outside == 0 then
		return LobbyStart.gather(record)
	end

	local token = nextToken
	nextToken = nextToken + 1
	local timeoutSec = math.max(5, math.floor(tonumber(ExpeditionConfig.TEAM_ACCEPT_TIMEOUT_SEC) or LobbyConfig.CALL_TIMEOUT_SEC))
	local call = {
		token = token,
		deadline = os.time() + timeoutSec,
		pending = pending,
		accepted = {},
	}
	rt.call = call
	call.event = addEvent(onTimeout, timeoutSec * 1000, record.id, token)

	for guid in pairs(pending) do
		local p = online(guid)
		if p then
			LobbyProtocol.send(p, {
				type = "call",
				lobbyId = record.id,
				hostName = record.hostName,
				expeditionName = record.expeditionName,
				deadline = call.deadline,
				timeoutSec = timeoutSec,
			})
			p:sendTextMessage(
				MESSAGE_EVENT_ADVANCE,
				string.format("%s is starting %s. Join the lobby to play.", record.hostName, record.expeditionName)
			)
		end
	end
	broadcast(record)
	return true
end

--- Called member answered. Accepting channels them into the room (ending a solo run).
function LobbyStart.answerCall(player, accept)
	local record = LobbyStore.getForPlayer(player)
	local call = record and LobbyStore.runtime(record).call
	local guid = player:getGuid()
	if not call or not call.pending[guid] then
		return false, "No lobby call is pending."
	end
	if not accept then
		LobbyStart.cancel(record, string.format("Lobby start cancelled: %s declined.", player:getName()))
		return true
	end
	if call.accepted[guid] then
		return true
	end
	call.accepted[guid] = true
	local lobbyId, token = record.id, call.token
	local function stillCalling()
		local live = LobbyStore.get(lobbyId)
		local liveCall = live and LobbyStore.runtime(live).call
		return liveCall ~= nil and liveCall.token == token, live
	end
	local ok, err = InstanceTeleport.requestLobby(player, record, {
		fromExpedition = ExpeditionManager.getSessionByPlayer(player) ~= nil,
		onComplete = function(p, entered, enterErr)
			local calling, live = stillCalling()
			if calling and not entered then
				LobbyStart.cancel(live, string.format("Lobby start cancelled: %s could not reach the lobby (%s).",
					p:getName(), tostring(enterErr or "blocked")))
			end
		end,
		onCancel = function(p)
			local calling, live = stillCalling()
			if calling then
				LobbyStart.cancel(live, string.format("Lobby start cancelled: %s stopped traveling.",
					p and p:getName() or "a member"))
			end
		end,
	})
	if not ok then
		call.accepted[guid] = nil
		LobbyStart.cancel(record, string.format("Lobby start cancelled: %s cannot travel (%s).",
			player:getName(), tostring(err or "blocked")))
		return false, err
	end
	broadcast(record)
	return true
end

--- LobbyInstance hook: someone stepped into their lobby room.
function LobbyStart.onEnteredRoom(player, record)
	local call = record and LobbyStore.runtime(record).call
	if not call or not call.pending[player:getGuid()] then
		return
	end
	call.pending[player:getGuid()] = nil
	if next(call.pending) == nil then
		if call.event then
			stopEvent(call.event)
			call.event = nil
		end
		local ok, err = LobbyStart.gather(record)
		if not ok then
			LobbyStart.cancel(record, err)
		end
		return
	end
	broadcast(record)
end

function LobbyStart.onMemberLogout(player)
	local record = LobbyStore.getForPlayer(player)
	if not record or not LobbyStart.isActive(record) then
		return
	end
	if Alts.isCompanion(player) and not Alts.isRealUiClient(player) then
		return
	end
	LobbyStart.cancel(record, string.format("Lobby start cancelled: %s logged out.", player:getName()))
end

function LobbyStart.onMemberRemoved(record, guid)
	if not LobbyStart.isActive(record) then
		return
	end
	local rt = LobbyStore.runtime(record)
	if rt.call then
		rt.call.pending[guid] = nil
		rt.call.accepted[guid] = nil
	end
	LobbyStart.cancel(record, "Lobby start cancelled: the lobby roster changed.")
end
