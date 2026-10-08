-- Token services (opcode 127): item renew, imbuement materials, token quotes.

local loginEvent = CreatureEvent("TokenServicesLogin")

function loginEvent.onLogin(player)
	player:registerEvent("TokenServicesOpcode")
	return true
end

loginEvent:register()

local opcodeEvent = CreatureEvent("TokenServicesOpcode")

function opcodeEvent.onExtendedOpcode(player, opcode, buffer)
	if opcode ~= TokenServicesConfig.OPCODE then
		return
	end
	local ok, err = pcall(TokenServices.handleOpcode, player, buffer)
	if not ok then
		logger.error("[TokenServices] opcode failed: {}", err)
	end
end

opcodeEvent:register()
