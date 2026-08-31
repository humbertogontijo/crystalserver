-- Shared gate for HUD teleports (home, expedition).
-- Allowed from any protection-zone tile, or while inside a personal home instance.
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

function PzTeleport.isAllowed(player)
	if not player then
		return false, "Invalid player."
	end
	if PzTeleport.isGod(player) then
		return true
	end
	if player.isPzLocked and player:isPzLocked() then
		return false, PzTeleport.PZ_LOCKED_MESSAGE
	end
	if PlayerHomeManager and PlayerHomeManager.isPlayerInHome and PlayerHomeManager.isPlayerInHome(player) then
		return true
	end
	local tile = Tile(player:getPosition())
	if not tile or not tile:hasFlag(TILESTATE_PROTECTIONZONE) then
		return false, PzTeleport.FAIL_MESSAGE
	end
	return true
end
