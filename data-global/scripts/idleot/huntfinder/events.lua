-- Hunt Finder: monster stats + item ids for OTC (opcode 252).

logger.info("[HuntFinder] ready (opcode {})", HuntFinderConfig.OPCODE or 252)

local loginEvent = CreatureEvent("HuntFinderLogin")

function loginEvent.onLogin(player)
	player:registerEvent("HuntFinderOpcode")
	return true
end

loginEvent:register()

local opcodeEvent = CreatureEvent("HuntFinderOpcode")

function opcodeEvent.onExtendedOpcode(player, opcode, buffer)
	if opcode ~= HuntFinderConfig.OPCODE then
		return
	end
	local ok, err = pcall(function()
		HuntFinderProtocol.handle(player, buffer)
	end)
	if not ok then
		logger.error("[HuntFinder] opcode handler failed: {}", err)
	end
end

opcodeEvent:register()
