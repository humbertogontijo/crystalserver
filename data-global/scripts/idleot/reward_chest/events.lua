-- Boss reward chest open/collect from anywhere (opcode 124).
-- Client: { "action": "open" | "collect" }

local loginEvent = CreatureEvent("RewardChestLogin")

function loginEvent.onLogin(player)
	player:registerEvent("RewardChestOpcode")
	if RewardChest and RewardChest.sendStatus then
		local pid = player:getId()
		addEvent(function()
			local p = Player(pid)
			if not p then
				return
			end
			RewardChest.sendStatus(p)
		end, 1500)
	end
	return true
end

loginEvent:register()

local opcodeEvent = CreatureEvent("RewardChestOpcode")

function opcodeEvent.onExtendedOpcode(player, opcode, buffer)
	if not RewardChestConfig or opcode ~= RewardChestConfig.OPCODE then
		return
	end
	if RewardChest and RewardChest.handleOpcode then
		local ok, err = pcall(RewardChest.handleOpcode, player, buffer)
		if not ok then
			logger.error("[RewardChest] opcode handler failed: {}", err)
		end
	end
end

opcodeEvent:register()
