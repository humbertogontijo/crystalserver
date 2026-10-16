-- Base helpers for orchestrator controllers (Boss / Mission / party hunt).
-- Orchestrators hold PlayerControllers and decide which one acts.

IdleOrchestrator = IdleOrchestrator or {}
IdleOrchestrator.__index = IdleOrchestrator

function IdleOrchestrator.new(opts)
	opts = opts or {}
	return setmetatable({
		name = opts.name or "orchestrator",
		_controllers = {}, -- playerId → PlayerController
	}, IdleOrchestrator)
end

function IdleOrchestrator:controllerFor(player)
	if not player then
		return nil
	end
	local id = player:getId()
	local ctrl = self._controllers[id]
	if not ctrl then
		ctrl = PlayerController.get(player)
		self._controllers[id] = ctrl
	end
	return ctrl
end

function IdleOrchestrator:forget(playerId)
	self._controllers[playerId] = nil
end

function IdleOrchestrator:clearControllers()
	self._controllers = {}
end

--- Nearest agent PlayerController to `position` (within optional range).
function IdleOrchestrator:nearestAgent(players, position, range)
	local best, bestDist = nil, nil
	for _, player in ipairs(players or {}) do
		local ctrl = self:controllerFor(player)
		if ctrl and ctrl:isAgent(player) then
			local dist = CombatGeo.chebyshev(player:getPosition(), position)
			if dist ~= math.huge and (not range or dist <= range) and (not bestDist or dist < bestDist) then
				best, bestDist = ctrl, dist
			end
		end
	end
	return best
end

function IdleOrchestrator:tick()
	for _, ctrl in pairs(self._controllers) do
		if ctrl.tick then
			ctrl:tick()
		end
	end
end
