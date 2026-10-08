-- Social friends (opcode 121).

local loginEvent = CreatureEvent("SocialLogin")

function loginEvent.onLogin(player)
	player:registerEvent("SocialOpcode")
	local ok, err = pcall(function()
		FriendsStore.applyPendingAccepts(player)
	end)
	if not ok then
		logger.error("[Social] applyPendingAccepts failed for {}: {}", player:getName(), err)
	end
	return true
end

loginEvent:register()

local opcodeEvent = CreatureEvent("SocialOpcode")

function opcodeEvent.onExtendedOpcode(player, opcode, buffer)
	if opcode ~= SocialConfig.OPCODE then
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

local startup = GlobalEvent("SocialStartup")

function startup.onStartup()
	logger.info("[Social] friends ready (opcode {})", SocialConfig.OPCODE or 121)
	return true
end

startup:register()
