-- personal home instance (top-bar Home button).
-- Client extended opcode 116
--   → { "action": "goHome" } | { "action": "leaveHome" }
--   ← { "type": "error", "message": "..." }

local loginEvent = CreatureEvent("PlayerHomeLogin")

function loginEvent.onLogin(player)
	player:registerEvent("PlayerHomeOpcode")
	player:registerEvent("PlayerHomeLogout")
	player:registerEvent("PlayerHomeDeath")
	if PlayerHomeManager and PlayerHomeManager.onLogin then
		pcall(PlayerHomeManager.onLogin, player)
	end
	return true
end

loginEvent:register()

local opcodeEvent = CreatureEvent("PlayerHomeOpcode")

function opcodeEvent.onExtendedOpcode(player, opcode, buffer)
	if not PlayerHomeConfig or opcode ~= PlayerHomeConfig.OPCODE then
		return
	end
	if PlayerHomeManager and PlayerHomeManager.handleOpcode then
		local ok, err = pcall(PlayerHomeManager.handleOpcode, player, buffer)
		if not ok then
			logger.error("[PlayerHome] opcode handler failed: {}", err)
		end
	end
end

opcodeEvent:register()

local logoutEvent = CreatureEvent("PlayerHomeLogout")

function logoutEvent.onLogout(player)
	if PlayerHomeManager and PlayerHomeManager.onLogout then
		local ok, result = pcall(PlayerHomeManager.onLogout, player)
		if not ok then
			logger.error("[PlayerHome] onLogout failed for {}: {}", player:getName(), result)
			return true
		end
		if result == false then
			return false
		end
	end
	return true
end

logoutEvent:register()

local deathEvent = CreatureEvent("PlayerHomeDeath")

function deathEvent.onDeath(player, corpse, killer, mostDamageKiller, lastHitUnjustified, mostDamageUnjustified)
	if PlayerHomeManager and PlayerHomeManager.onDeath then
		pcall(PlayerHomeManager.onDeath, player)
	end
	return true
end

deathEvent:register()

local startup = GlobalEvent("PlayerHomeStartup")

function startup.onStartup()
	if PlayerHomeManager and PlayerHomeManager.onStartup then
		PlayerHomeManager.onStartup()
	end
	return true
end

startup:register()

-- Persist open homes before map/house saves when global save fires.
local saveEvent = GlobalEvent("PlayerHomeSave")

function saveEvent.onSave()
	if PlayerHomeManager and PlayerHomeManager.onServerSave then
		pcall(PlayerHomeManager.onServerSave)
	end
	return true
end

saveEvent:register()
