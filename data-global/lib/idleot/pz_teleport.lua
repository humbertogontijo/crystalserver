-- Shared gate helpers for instance teleport durations (PZ vs wilderness).
-- isAllowed remains the hard gate for legacy callers; IT uses isInSafeZone + isCombatLocked.
PzTeleport = PzTeleport or {}

PzTeleport.FAIL_MESSAGE = "You can only teleport from a protection zone."
PzTeleport.PZ_LOCKED_MESSAGE = "You cannot teleport while PZ-locked."

function PzTeleport.isGod(player)
	if not player or not player.getGroup then
		return false
	end
	local group = player:getGroup()
	if not group or not group.getId then
		return false
	end
	local godId = GROUP_TYPE_GOD or 6
	return group:getId() == godId
end

--- True if standing on a PZ tile or inside a personal home instance.
function PzTeleport.isInSafeZone(player)
	if not player then
		return false
	end
	if PlayerHomeManager and PlayerHomeManager.isPlayerInHome and PlayerHomeManager.isPlayerInHome(player) then
		return true
	end
	local tile = Tile(player:getPosition())
	return tile and tile:hasFlag(TILESTATE_PROTECTIONZONE) and true or false
end

function PzTeleport.isCombatLocked(player)
	if not player then
		return true
	end
	return player.isPzLocked and player:isPzLocked() and true or false
end

function PzTeleport.isAllowed(player)
	if not player then
		return false, "Invalid player."
	end
	if PzTeleport.isGod(player) then
		return true
	end
	if PzTeleport.isCombatLocked(player) then
		return false, PzTeleport.PZ_LOCKED_MESSAGE
	end
	if PzTeleport.isInSafeZone(player) then
		return true
	end
	return false, PzTeleport.FAIL_MESSAGE
end
