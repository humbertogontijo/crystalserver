-- ============================================================================
-- Echo Warden Portal - item 54133 (live) / 54134 (per-instance spent claim)
-- Use from adjacent sqm or step-in. Shared instance-0 portals claim via door-style fork.
-- ============================================================================

local echoUse = Action()

function echoUse.onUse(player, item, fromPosition, target, toPosition, isHotkey)
	if not player or not item then
		return false
	end
	-- Use the item's map position (adjacent use); ignore target/toPosition.
	local pos = item.getPosition and item:getPosition() or fromPosition
	return EchoWarden.activateFromItem(player, item, pos)
end

echoUse:id(EchoWarden.PORTAL_ITEM_ID)
echoUse:register()

local echoPortal = MoveEvent()

function echoPortal.onStepIn(creature, item, position, fromPosition)
	local player = creature and creature:getPlayer()
	if not player then
		return true
	end
	EchoWarden.activateFromItem(player, item, position)
	return true
end

echoPortal:type("stepin")
echoPortal:id(EchoWarden.PORTAL_ITEM_ID)
echoPortal:register()
