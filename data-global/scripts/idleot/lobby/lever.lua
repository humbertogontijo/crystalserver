-- Cloned lever in a lever-boss lobby room: the host's pull is the Start button. The lever item
-- is shared by every lobby on this room variant, so it never flips; feedback goes only to the
-- puller's room.

local lever = Action()

local function roomEffect(room, pos, effect)
	for _, p in ipairs(LobbyInstance.occupants(room)) do
		pos:sendMagicEffect(effect, p)
	end
end

function lever.onUse(player, item, _fromPosition, _target, _toPosition, _isHotkey)
	local room = LobbyInstance.roomForPlayer(player)
	local record = room and LobbyStore.get(room.lobbyId)
	if not record then
		player:sendCancelMessage("This lever only works inside your lobby room.")
		return true
	end
	if record.hostGuid ~= player:getGuid() then
		player:sendCancelMessage("Only the lobby host can pull the lever.")
		return true
	end
	local ok, err = LobbyStart.request(player, {})
	if ok then
		roomEffect(room, item:getPosition(), CONST_ME_MAGIC_BLUE)
	elseif err then
		player:sendCancelMessage(err)
	end
	return true
end

lever:aid(LobbyConfig.LEVER_ACTION_ID)
lever:register()
