-- Social friends + expedition matchmaking (opcode 121).

local loginEvent = CreatureEvent("SocialLogin")

function loginEvent.onLogin(player)
	player:registerEvent("SocialOpcode")
	player:registerEvent("SocialLogout")
	if FriendsStore and FriendsStore.applyPendingAccepts then
		local ok, err = pcall(function()
			FriendsStore.applyPendingAccepts(player)
		end)
		if not ok then
			logger.error("[Social] applyPendingAccepts failed for {}: {}", player:getName(), err)
		end
	end
	if ListingsStore and ListingsStore.onLogin then
		local ok, err = pcall(function()
			ListingsStore.onLogin(player)
			-- Defer wire push so the client has finished entering the game world.
			addEvent(function(pid)
				local p = Player(pid)
				if p and SocialProtocol and SocialProtocol.sendMyListing then
					SocialProtocol.sendMyListing(p)
				end
			end, 500, player:getId())
		end)
		if not ok then
			logger.error("[Social] ListingsStore.onLogin failed for {}: {}", player:getName(), err)
		end
	end
	return true
end

loginEvent:register()

local opcodeEvent = CreatureEvent("SocialOpcode")

function opcodeEvent.onExtendedOpcode(player, opcode, buffer)
	if not SocialConfig or opcode ~= SocialConfig.OPCODE then
		return
	end
	local ok, err = pcall(function()
		SocialProtocol.handle(player, buffer)
	end)
	if not ok then
		logger.error("[Social] opcode handler failed: {}", err)
	end
end

opcodeEvent:register()

local logoutEvent = CreatureEvent("SocialLogout")

function logoutEvent.onLogout(player)
	if ListingsStore and ListingsStore.onLogout then
		local ok, err = pcall(function()
			ListingsStore.onLogout(player)
		end)
		if not ok then
			logger.error("[Social] onLogout failed for {}: {}", player:getName(), err)
		end
	end
	return true
end

logoutEvent:register()

local startup = GlobalEvent("SocialStartup")

function startup.onStartup()
	logger.info("[Social] friends + matchmaking ready (opcode {})", SocialConfig and SocialConfig.OPCODE or 121)
	return true
end

startup:register()
