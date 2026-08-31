-- Free auto vocation promotion at level 20 (no NPC / !promotion / gold).
-- Also re-applies on login so free accounts keep promotion after stock premium demotion.

local REQUIRED_LEVEL = 20

--- @return boolean true if vocation was changed this call
local function tryAutoPromote(player, notify)
	if not player then
		return false
	end
	if player:getLevel() < REQUIRED_LEVEL then
		return false
	end

	local vocation = player:getVocation()
	if not vocation or vocation:getId() == VOCATION_NONE then
		return false
	end

	local promotion = vocation:getPromotion()
	if not promotion then
		-- Already on a top-tier vocation: still mark KV so login re-apply stays consistent.
		if player:isPromoted() and not player:kv():get("promoted") then
			player:kv():set("promoted", true)
		end
		return false
	end

	if player:isPromoted() then
		if not player:kv():get("promoted") then
			player:kv():set("promoted", true)
		end
		return false
	end

	local firstTime = not player:kv():get("promoted")
	player:setVocation(promotion)
	player:kv():set("promoted", true)

	if firstTime then
		player:addMinorCharmEchoes(100)
		if notify then
			player:sendTextMessage(
				MESSAGE_EVENT_ADVANCE,
				"You have been automatically promoted for reaching level " .. REQUIRED_LEVEL .. "!"
			)
			player:sendBannerType(BANNER_TYPE_PROMOTION_GRANTED)
			local pos = player:getPosition()
			if pos then
				pos:sendMagicEffect(CONST_ME_HOLYDAMAGE)
			end
		end
	end

	return true
end

local loginEvent = CreatureEvent("AutoPromoteLogin")

function loginEvent.onLogin(player)
	player:registerEvent("AutoPromoteAdvance")
	-- Defer so this runs after stock PlayerLoginGlobal (which demotes free accounts).
	local playerId = player:getId()
	addEvent(function(id)
		local p = Player(id)
		if p then
			-- notify only on first-time catch-up (tryAutoPromote gates messaging)
			tryAutoPromote(p, true)
		end
	end, 50, playerId)
	return true
end

loginEvent:register()

local advanceEvent = CreatureEvent("AutoPromoteAdvance")

function advanceEvent.onAdvance(player, skill, oldLevel, newLevel)
	if skill ~= SKILL_LEVEL or newLevel <= oldLevel then
		return true
	end
	if newLevel < REQUIRED_LEVEL then
		return true
	end
	tryAutoPromote(player, true)
	return true
end

advanceEvent:register()
