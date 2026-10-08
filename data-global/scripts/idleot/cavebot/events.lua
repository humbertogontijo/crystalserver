local loginEvent = CreatureEvent("CavebotLogin")

function loginEvent.onLogin(player)
	player:registerEvent("CavebotLogout")
	return true
end

loginEvent:register()

local logoutEvent = CreatureEvent("CavebotLogout")

function logoutEvent.onLogout(player)
	local ok, err = pcall(CavebotService.onLogout, player)
	if not ok then
		logger.error("[Cavebot] onLogout failed for {}: {}", player:getName(), err)
	end
	return true
end

logoutEvent:register()

-- Open-world runs: monsters adopted by CavebotPack.adoptEngaged.
local monsterDeath = CreatureEvent("CavebotMonsterDeath")

function monsterDeath.onDeath(creature)
	local ok, err = pcall(CavebotPack.onMonsterDeath, creature)
	if not ok then
		logger.error("[Cavebot] monster death failed: {}", err)
	end
	return true
end

monsterDeath:register()
