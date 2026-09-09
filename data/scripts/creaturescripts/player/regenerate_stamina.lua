local regenerateStamina = CreatureEvent("RegenerateStamina")

function regenerateStamina.onLogin(player)
	if not configManager.getBoolean(configKeys.STAMINA_SYSTEM) then
		return true
	end

	local staminaRegained = 0
	local lastLogout = player:getLastLogout()
	local offlineTime = (lastLogout ~= 0) and math.min(os.time() - lastLogout, 86400 * 21) or 0
	offlineTime = offlineTime - 600

	if offlineTime < 180 then
		return true
	end

	local greenThreshold = STAMINA_GREEN_THRESHOLD or 2160
	local maxStamina = STAMINA_MAX_MINUTES or 2520
	local staminaMinutes = player:getStamina()
	local initialStamina = staminaMinutes
	local normalRegenSec = configManager.getNumber(configKeys.STAMINA_REGEN_MINUTE)
	local greenRegenSec = configManager.getNumber(configKeys.STAMINA_REGEN_PREMIUM)
	local maxNormalStaminaRegen = greenThreshold - math.min(greenThreshold, staminaMinutes)
	local regainStaminaMinutes = offlineTime / normalRegenSec

	if regainStaminaMinutes > maxNormalStaminaRegen then
		local happyHourStaminaRegen = (offlineTime - (maxNormalStaminaRegen * normalRegenSec)) / greenRegenSec
		staminaMinutes = math.min(maxStamina, math.max(greenThreshold, staminaMinutes) + happyHourStaminaRegen)
	else
		staminaMinutes = staminaMinutes + regainStaminaMinutes
	end

	player:setStamina(staminaMinutes)

	staminaRegained = math.floor(staminaMinutes - initialStamina)
	player:sendTextMessage(MESSAGE_EVENT_ADVANCE, "You have regenerated " .. staminaRegained .. " stamina minutes while you were offline.")

	return true
end

regenerateStamina:register()
