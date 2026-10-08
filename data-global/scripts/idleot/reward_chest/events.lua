-- Boss reward chest open/collect from anywhere (opcode 124).
-- Client: { "action": "open" | "collect" }

local loginEvent = CreatureEvent("RewardChestLogin")

function loginEvent.onLogin(player)
	player:registerEvent("RewardChestOpcode")
	return true
end

loginEvent:register()

local clientReadyCallback = EventCallback("RewardChestPlayerOnClientReady")

function clientReadyCallback.playerOnClientReady(player)
	RewardChest.sendStatus(player)
end

clientReadyCallback:register()

local opcodeEvent = CreatureEvent("RewardChestOpcode")

function opcodeEvent.onExtendedOpcode(player, opcode, buffer)
	if opcode ~= RewardChestConfig.OPCODE then
		return
	end
	local ok, err = pcall(RewardChest.handleOpcode, player, buffer)
	if not ok then
		logger.error("[RewardChest] opcode handler failed: {}", err)
	end
end

opcodeEvent:register()
