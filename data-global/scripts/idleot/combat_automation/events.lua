local loginEvent = CreatureEvent("CombatAutomationLogin")

function loginEvent.onLogin(player)
	local ok, err = pcall(function()
		CombatAutomationStore.onLogin(player)
	end)
	if not ok then
		logger.error("[CombatAutomation] onLogin failed for {}: {}", player:getName(), err)
	end
	return true
end

loginEvent:register()

-- The client has self and map now; deduped attackTarget syncs before this never paint.
local clientReadyCallback = EventCallback("CombatAutomationPlayerOnClientReady")

function clientReadyCallback.playerOnClientReady(player)
	CombatAutomation.resyncAttackTarget(player)
end

clientReadyCallback:register()

local logoutEvent = CreatureEvent("CombatAutomationLogout")

function logoutEvent.onLogout(player)
	local ok, err = pcall(function()
		CombatAutomationStore.onLogout(player)
	end)
	if not ok then
		logger.error("[CombatAutomation] onLogout failed for {}: {}", player:getName(), err)
	end
	return true
end

logoutEvent:register()

-- Core Creature:onTargetCombat only blocks player-vs-player party hits (and own summons).
-- Team/party auto-attack was locking onto allied familiars because they are monsters.
local targetCombat = EventCallback("TeamCreatureOnTargetCombat")

function targetCombat.creatureOnTargetCombat(creature, target)
	if not creature or not target then
		return RETURNVALUE_NOERROR
	end
	local attackerCtrl = CombatAutomation.controllingPlayer(creature)
	local targetCtrl = CombatAutomation.controllingPlayer(target)
	if not attackerCtrl or not targetCtrl then
		return RETURNVALUE_NOERROR
	end
	if attackerCtrl:getId() == targetCtrl:getId() then
		return RETURNVALUE_NOERROR
	end
	if not CombatAutomation.isAlliedPlayer(attackerCtrl, targetCtrl) then
		return RETURNVALUE_NOERROR
	end
	if creature:isMonster() or target:isMonster() then
		return RETURNVALUE_YOUMAYNOTATTACKTHISCREATURE
	end
	return RETURNVALUE_NOERROR
end

targetCombat:register()
