-- Remote blessings (opcode 119).

local loginEvent = CreatureEvent("RemoteBlessingsLogin")

function loginEvent.onLogin(player)
	player:registerEvent("RemoteBlessingsOpcode")
	if RemoteBlessings and RemoteBlessings.tryAutoRebuy then
		addEvent(function(pid)
			local p = Player(pid)
			if p then
				IdleSafe.call("RemoteBlessings.tryAutoRebuy", RemoteBlessings.tryAutoRebuy, p)
			end
		end, 1500, player:getId())
	end
	return true
end

loginEvent:register()

local opcodeEvent = CreatureEvent("RemoteBlessingsOpcode")

function opcodeEvent.onExtendedOpcode(player, opcode, buffer)
	if not RemoteBlessingsConfig or opcode ~= RemoteBlessingsConfig.OPCODE then
		return
	end
	local ok, err = pcall(function()
		RemoteBlessings.handleOpcode(player, buffer)
	end)
	if not ok then
		logger.error("[RemoteBlessings] opcode failed: {}", err)
	end
end

opcodeEvent:register()
