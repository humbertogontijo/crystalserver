-- PlayerController: extends CreatureController with player-only idle actions.

PlayerController = PlayerController or {}
setmetatable(PlayerController, { __index = CreatureController })
PlayerController.__index = PlayerController

local geo = CombatGeo
local byPlayerId = {}

--- True when the player can walk the last tiles. A lobby room or expedition always channels.
local function nearDestination(player, dest, reach)
	if not player or not dest then
		return false
	end
	if ExpeditionManager and ExpeditionManager.getSessionByPlayer and ExpeditionManager.getSessionByPlayer(player) then
		return false
	end
	if LobbyInstance and LobbyInstance.roomForPlayer and LobbyInstance.roomForPlayer(player) then
		return false
	end
	local pos = player:getPosition()
	if not pos or pos.z ~= dest.z then
		return false
	end
	local dist = geo.chebyshev(pos, dest)
	return dist ~= math.huge and dist <= reach
end

local function resolveNpc(nameOrNpc)
	if type(nameOrNpc) == "userdata" then
		return nameOrNpc
	end
	local want = tostring(nameOrNpc or ""):lower()
	if want == "" then
		return nil
	end
	for _, npc in ipairs(Game.getNpcs() or {}) do
		if npc:getName():lower() == want then
			return npc
		end
	end
	return nil
end

function PlayerController.get(player)
	if not player then
		return nil
	end
	local id = player:getId()
	local ctrl = byPlayerId[id]
	if ctrl and ctrl.creatureId == id then
		return ctrl
	end
	-- Build on CreatureController storage so creature verbs share the same instance.
	ctrl = CreatureController.get(player)
	setmetatable(ctrl, PlayerController)
	ctrl._jobQueue = ctrl._jobQueue or {}
	ctrl._jobRunning = false
	ctrl._scopeManual = nil -- optional: session.manualIds table
	byPlayerId[id] = ctrl
	return ctrl
end

function PlayerController.release(playerId)
	byPlayerId[playerId] = nil
	CreatureController.release(playerId)
end

function PlayerController:player()
	return Player(self.creatureId)
end

function PlayerController:bindManualMap(manualIds)
	self._scopeManual = manualIds
end

--- True while AI may drive this player (not paused / under manual control).
function PlayerController:isAgent(player)
	player = player or self:player()
	if not player or player:getHealth() <= 0 then
		return false
	end
	if self._scopeManual and self._scopeManual[player:getId()] then
		return false
	end
	if CombatAutomationMovement and CombatAutomationMovement.isManual(player) then
		return false
	end
	return true
end

function PlayerController:isDriven(actor)
	return self:isAgent(actor)
end

--- Walk to NPC (or fixed pos), re-check range + NPC presence, then say phrases.
--- Never says if the player yank-moved away mid-errand.
function PlayerController:talkTo(npcOrName, phrases, opts)
	opts = opts or {}
	local player = self:player()
	if not player then
		if opts.onDone then
			opts.onDone(nil, false, "gone")
		end
		return false
	end
	phrases = type(phrases) == "table" and phrases or { phrases }
	local reach = math.max(1, opts.reach or 3)
	local gapMs = tonumber(opts.phraseGapMs) or 1200

	local function fail(reason)
		if opts.onDone then
			opts.onDone(player, false, reason)
		end
		return false
	end

	local npc = resolveNpc(npcOrName)
	local dest = opts.position
	if npc then
		dest = npc:getPosition()
	elseif not dest then
		return fail("missing")
	end

	local wrapped = {}
	for k, v in pairs(opts) do
		wrapped[k] = v
	end
	wrapped.reach = reach
	wrapped.keepGoing = function(p)
		if not self:isAgent(p) then
			return false
		end
		if opts.keepGoing and opts.keepGoing(p) == false then
			return false
		end
		return true
	end
	wrapped.onDone = function(p, ok, reason)
		if not ok or not p then
			if opts.onDone then
				opts.onDone(p, false, reason or "failed")
			end
			return
		end
		-- Re-validate before any speech.
		local target = resolveNpc(npcOrName) or npc
		if not target then
			if opts.onDone then
				opts.onDone(p, false, "missing")
			end
			return
		end
		local dist = geo.chebyshev(p:getPosition(), target:getPosition())
		if dist == math.huge or dist > reach then
			if opts.onDone then
				opts.onDone(p, false, "outofrange")
			end
			return
		end
		if not self:isAgent(p) then
			if opts.onDone then
				opts.onDone(p, false, "manual")
			end
			return
		end
		geo.faceToward(p, target:getPosition())
		local i = 0
		local function sayNext()
			i = i + 1
			local live = Player(self.creatureId)
			if not live or not self:isAgent(live) then
				if opts.onDone then
					opts.onDone(live, false, "manual")
				end
				return
			end
			local still = resolveNpc(npcOrName)
			if not still then
				if opts.onDone then
					opts.onDone(live, false, "missing")
				end
				return
			end
			local d = geo.chebyshev(live:getPosition(), still:getPosition())
			if d == math.huge or d > reach then
				if opts.onDone then
					opts.onDone(live, false, "outofrange")
				end
				return
			end
			local text = phrases[i]
			if not text then
				if opts.onDone then
					opts.onDone(live, true)
				end
				return
			end
			-- Private NPC speech: the NPC keyword handler only continues a
			-- conversation on TALKTYPE_PRIVATE_PN, and that opens the client
			-- NPC dialog. The second say echoes the line to this player only
			-- (mode 12) so it lands on the NPCs tab; nearby players do not see it.
			local line = tostring(text)
			live:say(line, TALKTYPE_PRIVATE_PN, false, still)
			live:say(line, TALKTYPE_PRIVATE_PN, false, live)
			addEvent(sayNext, gapMs)
		end
		sayNext()
	end

	if not opts._afterChannel and not nearDestination(player, dest, reach) and InstanceTeleport and InstanceTeleport.requestOpenWorld then
		local landing = Position(dest.x + 1, dest.y, dest.z)
		local creatureId = self.creatureId
		local ok, err = InstanceTeleport.requestOpenWorld(player, landing, {
			onComplete = function(p, hopped, reason)
				if not hopped then
					if opts.onDone then
						opts.onDone(p, false, reason or "failed")
					end
					return
				end
				local ctrl = PlayerController.get(p or Player(creatureId))
				if not ctrl then
					if opts.onDone then
						opts.onDone(p, false, "gone")
					end
					return
				end
				local again = {}
				for k, v in pairs(opts) do
					again[k] = v
				end
				again._afterChannel = true
				ctrl:talkTo(npcOrName, phrases, again)
			end,
			onCancel = function(p)
				if opts.onDone then
					opts.onDone(p, false, "cancelled")
				end
			end,
		})
		if not ok then
			return fail(err or "Could not travel.")
		end
		return true
	end

	return PlayerErrand.walkTo(player, dest, wrapped)
end

--- Ordered jobs: `job(player, done)`; waits while not agent.
function PlayerController:queue(job, onDrop)
	local jobs = self._jobQueue
	jobs[#jobs + 1] = { run = job, drop = onDrop }
	self:_pumpQueue()
end

function PlayerController:_pumpQueue()
	if self._jobRunning then
		return
	end
	local job = self._jobQueue[1]
	if not job then
		return
	end
	local player = self:player()
	if player and not self:isAgent(player) then
		return
	end
	self._jobRunning = true
	local finished = false
	local function done()
		if finished then
			return
		end
		finished = true
		table.remove(self._jobQueue, 1)
		self._jobRunning = false
		addEvent(function()
			local ctrl = byPlayerId[self.creatureId]
			if ctrl then
				ctrl:_pumpQueue()
			end
		end, 0)
	end
	if not player then
		if job.drop then
			IdleSafe.call("PlayerController.drop", job.drop)
		end
		return done()
	end
	local ok, err = pcall(job.run, player, done)
	if not ok then
		logger.error("[PlayerController] job failed: {}", tostring(err))
		done()
	end
end

--- Resume queued jobs after manual control ends (call from think / orchestrator tick).
function PlayerController:tick()
	if not self._jobRunning and self._jobQueue[1] then
		self:_pumpQueue()
	end
end

IdleEvents.on("player.logout", function(player)
	if player then
		PlayerController.release(player:getId())
	end
end, "PlayerController")
