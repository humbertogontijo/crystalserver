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

-- Party changes regroup open-world runs (CavebotService regroups on the next tick, once
-- the change is applied: these callbacks run before it and only allow it).
local partyJoin = EventCallback("CavebotPartyJoin")

function partyJoin.partyOnJoin(_party, player)
	CavebotService.onMembershipChange(player)
	return true
end

partyJoin:register()

local partyLeave = EventCallback("CavebotPartyLeave")

function partyLeave.partyOnLeave(_party, player)
	CavebotService.onMembershipChange(player)
	return true
end

partyLeave:register()

local partyDisband = EventCallback("CavebotPartyDisband")

function partyDisband.partyOnDisband(_party)
	CavebotService.requestRegroup()
	return true
end

partyDisband:register()
