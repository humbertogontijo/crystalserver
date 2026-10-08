-- Reward letters: login delivery + status push, opcode 128 (claim / status).

local loginEvent = CreatureEvent("LetterLogin")

function loginEvent.onLogin(player)
	player:registerEvent("LetterOpcode")
	local ok, err = pcall(Letters.deliverPending, player)
	if not ok then
		logger.error("[Letters] delivery failed for {}: {}", player:getName(), err)
	end
	local playerId = player:getId()
	addEvent(function()
		local target = Player(playerId)
		if target then
			Letters.sendStatus(target)
		end
	end, 1500)
	return true
end

loginEvent:register()

local logoutEvent = CreatureEvent("LetterLogout")

function logoutEvent.onLogout(player)
	Letters.forget(player:getId())
	return true
end

logoutEvent:register()

local opcodeEvent = CreatureEvent("LetterOpcode")

function opcodeEvent.onExtendedOpcode(player, opcode, buffer)
	if opcode ~= LetterConfig.OPCODE then
		return
	end
	local ok, err = pcall(Letters.handleOpcode, player, buffer)
	if not ok then
		logger.error("[Letters] opcode handler failed: {}", err)
	end
end

opcodeEvent:register()
