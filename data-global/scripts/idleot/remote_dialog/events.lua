-- Remote dialog transport (opcode 120).

local loginEvent = CreatureEvent("RemoteDialogLogin")

function loginEvent.onLogin(player)
	player:registerEvent("RemoteDialogOpcode")
	return true
end

loginEvent:register()

local opcodeEvent = CreatureEvent("RemoteDialogOpcode")

function opcodeEvent.onExtendedOpcode(player, opcode, buffer)
	if opcode ~= RemoteDialogConfig.OPCODE then
		return
	end
	local ok, err = pcall(RemoteDialog.handleOpcode, player, buffer)
	if not ok then
		logger.error("[RemoteDialog] opcode failed: {}", err)
	end
end

opcodeEvent:register()

local logoutEvent = CreatureEvent("RemoteDialogLogout")

function logoutEvent.onLogout(player)
	RemoteDialog.onLogout(player)
	return true
end

logoutEvent:register()
