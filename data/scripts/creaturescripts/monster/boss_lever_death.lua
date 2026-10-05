local onBossDeath = CreatureEvent("BossLeverOnDeath")

function onBossDeath.onDeath(creature)
	if not creature then
		return true
	end

	local name = creature:getName()
	local bossLever = BossLever.get(name) or BossLever.forFinalBoss(name)
	if not bossLever then
		return true
	end
	if not bossLever:isFinalBoss(name) then
		if bossLever:isChained() then
			return true
		end
	else
		bossLever:onEncounterVictory(creature:getInstanceId())
	end
	-- Private-instance fights (expeditions) own their exit; the room timers are open-world only.
	if creature:getInstanceId() ~= 0 then
		return true
	end

	local zone = bossLever:getZone()
	if not zone then
		return true
	end

	if bossLever.timeoutEvent then
		stopEvent(bossLever.timeoutEvent)
		bossLever.timeoutEvent = nil
	end

	if bossLever.timeAfterKill > 0 then
		zone:sendTextMessage(MESSAGE_EVENT_ADVANCE, "The " .. name .. " has been defeated. You have " .. bossLever.timeAfterKill .. " seconds to leave the room.")
		bossLever.timeoutEvent = addEvent(function(zn)
			zn:refresh()
			zn:removePlayers()
		end, bossLever.timeAfterKill * 1000, zone)
	end
	onDeathForDamagingPlayers(creature, function(creature, player)
		player:sendBannerType(BANNER_TYPE_BOSSDEFEATED)
	end)
	return true
end

onBossDeath:register()
