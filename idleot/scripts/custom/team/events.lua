-- account team: extended opcode + lifecycle registration.

local loginEvent = CreatureEvent("TeamLogin")

function loginEvent.onLogin(player)
	player:registerEvent("TeamOpcode")
	player:registerEvent("TeamLogout")
	if TeamStore and TeamStore.reconcileControllerPointer then
		pcall(TeamStore.reconcileControllerPointer, player)
	end
	if TeamBonus and TeamBonus.onMemberLogin then
		pcall(TeamBonus.onMemberLogin, player)
	end
	addEvent(function(pid)
		local p = Player(pid)
		if p and TeamProtocol and TeamProtocol.sendTeam then
			TeamProtocol.sendTeam(p)
		end
	end, 500, player:getId())
	return true
end

loginEvent:register()

local opcodeEvent = CreatureEvent("TeamOpcode")

function opcodeEvent.onExtendedOpcode(player, opcode, buffer)
	if not TeamConfig or opcode ~= TeamConfig.OPCODE then
		return
	end
	local ok, err = pcall(function()
		TeamProtocol.handle(player, buffer)
	end)
	if not ok then
		logger.error("[Team] opcode handler failed: {}", err)
	end
end

opcodeEvent:register()

local logoutEvent = CreatureEvent("TeamLogout")

function logoutEvent.onLogout(player)
	if TeamManager and TeamManager.getDeployment and TeamManager.getDeployment(player) then
		local ok, err = pcall(function()
			-- Primary disconnect: companions must not stay online headless.
			if ExpeditionManager and ExpeditionManager.getSessionByPlayer then
				local session = ExpeditionManager.getSessionByPlayer(player)
				if session and ExpeditionManager.leaveAll then
					-- Eject companions from expedition before logout cleanup.
					for _, id in ipairs(ExpeditionManager.sessionMemberIds(session) or {}) do
						local member = Player(id)
						if member and member:getId() ~= player:getId() and TeamManager.isCompanion(member) then
							ExpeditionManager.leave(member, { silent = true, skipTeamUndeploy = true })
						end
					end
				end
			end
			TeamManager.undeploy(player)
		end)
		if not ok then
			logger.error("[Team] onLogout undeploy failed for {}: {}", player:getName(), err)
		end
	end
	return true
end

logoutEvent:register()
