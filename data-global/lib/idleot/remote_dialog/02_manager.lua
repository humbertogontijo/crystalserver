-- RemoteDialog: bind a player to a remote conversation (optionally a real NPC).
--
-- open(player, opts):
--   id       string   dialog id (e.g. "hireling")
--   name     string   display name
--   greet    string?  optional; if omitted and npc+handler set, simulates "hi"
--   outfit   table?   { type, head, body, legs, feet, addons }
--   buttons  table?   { { id=0, text="trade" }, ... }
--   npc      Npc?     bound NPC for private-PN forwarding
--   handler  NpcHandler?  if set with npc, say → handler:onSay(..., PRIVATE_PN, text)
--   onSay    function(player, text)?  custom say hook (runs after NPC forward)
--   onClose  function(player)?
--
-- NPC replies use engine TALKTYPE_PRIVATE_NP (cross-instance; see Game::internalCreatureSay).

RemoteDialog = RemoteDialog or {}

--- @type table<number, table> playerId → session
local sessions = {}

--- Outfit in the client's keys (accepts Outfit-style lookType/lookHead/... too).
local function clientOutfit(outfit)
	if type(outfit) ~= "table" then
		return nil
	end
	return {
		type = tonumber(outfit.type or outfit.lookType) or 0,
		head = tonumber(outfit.head or outfit.lookHead) or 0,
		body = tonumber(outfit.body or outfit.lookBody) or 0,
		legs = tonumber(outfit.legs or outfit.lookLegs) or 0,
		feet = tonumber(outfit.feet or outfit.lookFeet) or 0,
		addons = tonumber(outfit.addons or outfit.lookAddons) or 0,
	}
end

local function clientButtons(buttons)
	local out = {}
	for i, b in ipairs(type(buttons) == "table" and buttons or {}) do
		out[i] = { id = tonumber(b.id) or i, text = b.text or "" }
	end
	return out
end

local function reply(player, payload)
	if payload.type == "opened" then
		payload.outfit = clientOutfit(payload.outfit)
		payload.buttons = clientButtons(payload.buttons)
	end
	IdleUtil.sendJson(player, RemoteDialogConfig.OPCODE, payload)
end

local function getSession(player)
	if not player then
		return nil
	end
	return sessions[player:getId()]
end

local function clearSession(player)
	if not player then
		return
	end
	sessions[player:getId()] = nil
end

local function withInstantTalk(handler, fn)
	if not handler then
		return
	end
	local prevDelay = handler.talkDelayTimeForOutgoingMessages
	handler.talkDelayTimeForOutgoingMessages = 0
	IdleSafe.call("RemoteDialog.withInstantTalk", fn)
	handler.talkDelayTimeForOutgoingMessages = prevDelay or 1
end

--- Forward text to the bound NPC as private PN (engine-equivalent of playerSpeakToNpc for one NPC).
local function forwardPrivatePn(session, player, text)
	local npc = session.npcId and Npc(session.npcId) or nil
	local handler = session.handler
	if not npc or not handler or not handler.onSay then
		return false
	end
	if not handler:checkInteraction(npc, player) then
		handler:setInteraction(npc, player)
	end
	handler:onSay(npc, player, TALKTYPE_PRIVATE_PN, text)
	return true
end

function RemoteDialog.getSession(player)
	return getSession(player)
end

function RemoteDialog.isOpen(player)
	return getSession(player) ~= nil
end

--- Open (or replace) the remote dialog for this player.
function RemoteDialog.open(player, opts)
	if not player or not player:isPlayer() or type(opts) ~= "table" then
		return false
	end

	local npc = opts.npc
	local npcId = npc and npc:getId() or 0
	local name = opts.name or (npc and npc:getName()) or "NPC"
	local handler = opts.handler

	local session = {
		dialogId = tostring(opts.id or name),
		name = name,
		npcId = npcId,
		handler = handler,
		onSay = opts.onSay,
		onClose = opts.onClose,
		outfit = opts.outfit,
		buttons = opts.buttons,
	}
	sessions[player:getId()] = session

	local greet = opts.greet
	local simulateHi = opts.simulateHi
	if simulateHi == nil then
		simulateHi = handler ~= nil and npc ~= nil
	end
	if (greet == nil or greet == "") and handler and handler.getMessage then
		local raw = handler:getMessage(MESSAGE_GREET)
		if raw and raw ~= "" then
			greet = raw
			greet = greet:gsub("|PLAYERNAME|", player:getName())
		end
	end

	reply(player, {
		type = "opened",
		dialogId = session.dialogId,
		name = name,
		greet = greet or "",
		outfit = opts.outfit,
		buttons = opts.buttons,
		npcId = npcId,
	})

	-- Bind interaction so keyword/shop handlers work without a physical "hi" range check.
	if npc and handler then
		if not handler:checkInteraction(npc, player) then
			handler:setInteraction(npc, player)
		end
	end

	-- Drive FocusModule via "hi" only when greet was not already sent in `opened`.
	if simulateHi and npc and handler and (not greet or greet == "") then
		local pid = player:getId()
		local nid = npcId
		addEvent(function()
			local p = Player(pid)
			local n = Npc(nid)
			if not p or not n or not RemoteDialog.isOpen(p) then
				return
			end
			local sess = RemoteDialog.getSession(p)
			local h = sess and sess.handler or handler
			withInstantTalk(h, function()
				h:onSay(n, p, TALKTYPE_PRIVATE_PN, "hi")
			end)
		end, 150)
	end

	return true
end

function RemoteDialog.close(player, silent)
	local session = getSession(player)
	if not session then
		return
	end
	if session.onClose then
		IdleSafe.call("RemoteDialog.onClose", session.onClose, player)
	end

	local npc = session.npcId and Npc(session.npcId) or nil
	local handler = session.handler
	-- Window X without {bye}: still interacting → farewell. After bye, FocusModule already cleared it.
	if npc and handler and handler.checkInteraction and handler:checkInteraction(npc, player) then
		if handler.onSay then
			withInstantTalk(handler, function()
				handler:onSay(npc, player, TALKTYPE_PRIVATE_PN, "bye")
			end)
		elseif handler.removeInteraction then
			IdleSafe.call("RemoteDialog.removeInteraction", handler.removeInteraction, handler, npc, player)
		end
	end

	clearSession(player)
	if not silent then
		reply(player, { type = "closed" })
	end
end

function RemoteDialog.handleSay(player, text)
	if not player or type(text) ~= "string" or text == "" then
		return
	end
	local session = getSession(player)
	if not session then
		reply(player, { type = "error", message = "No remote dialog is open." })
		return
	end

	text = text:gsub("%c", ""):gsub("^%s+", ""):gsub("%s+$", "")
	if text == "" then
		return
	end

	local lower = text:lower()
	forwardPrivatePn(session, player, text)

	if session.onSay then
		IdleSafe.call("RemoteDialog.onSay", session.onSay, player, text)
	end

	if lower == "bye" or lower == "farewell" then
		-- Let NPC farewell PRIVATE_NP arrive first, then close the UI.
		addEvent(function(pid)
			local p = Player(pid)
			if p and RemoteDialog.isOpen(p) then
				RemoteDialog.close(p)
			end
		end, 400, player:getId())
	end
end

function RemoteDialog.handleOpcode(player, buffer)
	if type(buffer) ~= "string" or buffer == "" then
		return
	end
	local action = buffer:match('"action"%s*:%s*"([^"]+)"')
	if action == "say" then
		local text = buffer:match('"text"%s*:%s*"(.-)"') or ""
		text = text:gsub("\\n", "\n"):gsub('\\"', '"'):gsub("\\\\", "\\")
		RemoteDialog.handleSay(player, text)
		return
	end
	if action == "close" then
		RemoteDialog.close(player)
		return
	end
end

function RemoteDialog.onLogout(player)
	clearSession(player)
end
