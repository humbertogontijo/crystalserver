LootSplit = LootSplit or {}

-- leaderGuid → next round-robin index (persists across kills so first item rotates).
local rrCursorByLeader = {}

function LootSplit.findLootPouch(player)
	if not player or not player.getLootPouch then
		return nil
	end
	return player:getLootPouch()
end

local function isCoinItem(item)
	if not item then
		return false
	end
	local id = item:getId()
	local cfg = LootSplitConfig or {}
	return id == (cfg.GOLD_COIN_ID or 3031)
		or id == (cfg.PLATINUM_COIN_ID or 3035)
		or id == (cfg.CRYSTAL_COIN_ID or 3043)
end

local function itemWorth(item)
	if not item then
		return 0
	end
	if item.getWorth then
		return tonumber(item:getWorth()) or 0
	end
	local id = item:getId()
	local count = item:getCount() or 1
	local cfg = LootSplitConfig or {}
	if id == (cfg.GOLD_COIN_ID or 3031) then
		return count
	elseif id == (cfg.PLATINUM_COIN_ID or 3035) then
		return count * 100
	elseif id == (cfg.CRYSTAL_COIN_ID or 3043) then
		return count * 10000
	end
	return 0
end

local function playerAcceptsItem(player, item)
	if not player or not item then
		return false
	end
	if player.acceptsQuickLootItem then
		local ok, accepted = pcall(function()
			return player:acceptsQuickLootItem(item)
		end)
		if ok then
			return accepted == true
		end
	end
	return false
end

local function autoLootEnabled(player, isBoss)
	if not player or not player.getFeature or not Features or not Features.AutoLoot then
		return false
	end
	if configManager and configKeys and configManager.getBoolean then
		if not configManager.getBoolean(configKeys.AUTOLOOT) then
			return false
		end
	end
	local value = player:getFeature(Features.AutoLoot)
	value = tonumber(value) or 0
	if value == 2 then
		return true
	elseif value == 1 then
		return not isBoss
	end
	return false
end

local function sameInstance(a, b)
	if not a or not b or not a.getInstanceId or not b.getInstanceId then
		return true
	end
	return a:getInstanceId() == b:getInstanceId()
end

local function inRange(corpsePos, player)
	if not corpsePos or not player or not player.getPosition then
		return false
	end
	local pos = player:getPosition()
	if not pos then
		return false
	end
	local cfg = LootSplitConfig or {}
	local rangeXY = cfg.RANGE_XY or 30
	local rangeZ = cfg.RANGE_Z or 1
	local dx = math.abs((pos.x or 0) - (corpsePos.x or 0))
	local dy = math.abs((pos.y or 0) - (corpsePos.y or 0))
	local dz = math.abs((pos.z or 0) - (corpsePos.z or 0))
	return dx <= rangeXY and dy <= rangeXY and dz <= rangeZ
end

local function seatCanCarry(seatMember, item)
	if not seatMember or not item then
		return false
	end
	if not seatMember.getFreeCapacity or not item.getWeight then
		return true
	end
	local weight = tonumber(item:getWeight()) or 0
	if weight <= 0 then
		return true
	end
	return (tonumber(seatMember:getFreeCapacity()) or 0) >= weight
end

local function partyMembers(party)
	local members = {}
	if not party then
		return members
	end
	local leader = party.getLeader and party:getLeader() or nil
	if leader then
		members[#members + 1] = leader
	end
	local list = party.getMembers and party:getMembers() or {}
	for _, m in ipairs(list) do
		if m then
			members[#members + 1] = m
		end
	end
	return members
end

local function partyOnExpedition(party)
	if not party or not ExpeditionManager or not ExpeditionManager.getSessionByPlayer then
		return false
	end
	for _, member in ipairs(partyMembers(party)) do
		local session = ExpeditionManager.getSessionByPlayer(member)
		if session and session.entered then
			return true
		end
	end
	return false
end

--- True when at least one party body is near the corpse (hunt present on this kill).
local function partyClaimingCorpse(party, corpsePos)
	if not party or not corpsePos then
		return false
	end
	for _, member in ipairs(partyMembers(party)) do
		if member and inRange(corpsePos, member) then
			return true
		end
	end
	return false
end

--- Party-member seats only (account-blind). Each seat delivers to that member's pouch.
function LootSplit.seats(party, corpsePos, corpseCreature)
	if not party then
		return {}
	end
	if corpsePos and not partyClaimingCorpse(party, corpsePos) then
		return {}
	end

	local seats = {}
	for _, member in ipairs(partyMembers(party)) do
		local eligible = member ~= nil
		if eligible and corpseCreature and not sameInstance(member, corpseCreature) then
			eligible = false
		end
		if eligible then
			seats[#seats + 1] = member
		end
	end
	return seats
end

local function collectCorpseItems(corpse)
	local items = {}
	if not corpse or not corpse.getSize then
		return items
	end
	local size = corpse:getSize() or 0
	for i = size - 1, 0, -1 do
		local it = corpse:getItem(i)
		if it then
			if it.getSize and (it:getSize() or 0) > 0 then
				local nested = collectCorpseItems(it)
				for _, n in ipairs(nested) do
					items[#items + 1] = n
				end
			else
				items[#items + 1] = it
			end
		end
	end
	return items
end

--- Auto-sell + sell-on-no-cap: free pouch weight before stock/C++ auto-loot.
local function trySellForInsufficientCap(player, corpse, isBoss)
	if not player or not corpse then
		return false
	end
	if not RemoteHirelingEconomy or not RemoteHirelingEconomy.maybeSellForShortage then
		return false
	end
	if not autoLootEnabled(player, isBoss == true) then
		return false
	end
	if not player.getFreeCapacity then
		return false
	end

	local free = tonumber(player:getFreeCapacity()) or 0
	if free < 100 then
		return RemoteHirelingEconomy.maybeSellForShortage(player, "cap") == true
	end

	for _, it in ipairs(collectCorpseItems(corpse)) do
		if playerAcceptsItem(player, it) and not seatCanCarry(player, it) then
			return RemoteHirelingEconomy.maybeSellForShortage(player, "cap") == true
		end
	end
	return false
end

local function creditLootStats(player, itemId, count)
	if not player or not player.sendLootStats or not itemId or count <= 0 then
		return
	end
	if not Game or not Game.createItem then
		return
	end
	local statsItem = Game.createItem(itemId, count)
	if statsItem then
		player:sendLootStats(statsItem, count)
		statsItem:remove()
	end
end

--- Deliver to seat member's account pouch; credit analyser to the same seat.
local function deliverItem(destPlayer, item, statsPlayer)
	if not destPlayer or not item then
		return false, 0
	end
	statsPlayer = statsPlayer or destPlayer
	local itemId = item:getId()
	local count = item:getCount() or 1
	local worth = itemWorth(item)

	if isCoinItem(item) and worth > 0 then
		if item.remove then
			item:remove()
		end
		if destPlayer.addMoney then
			destPlayer:addMoney(worth)
		end
		local goldId = (LootSplitConfig and LootSplitConfig.GOLD_COIN_ID) or 3031
		local remaining = worth
		while remaining > 0 do
			local chunk = math.min(remaining, 100)
			creditLootStats(statsPlayer, goldId, chunk)
			remaining = remaining - chunk
		end
		return true, worth
	end

	if destPlayer.collectQuickLootItem then
		local ok, success = pcall(function()
			return destPlayer:collectQuickLootItem(item)
		end)
		if ok then
			if success == true then
				creditLootStats(statsPlayer, itemId, count)
				return true, 0
			end
			return false, 0
		end
	end

	local pouch = LootSplit.findLootPouch(destPlayer)
	local bp = destPlayer.getSlotItem and destPlayer:getSlotItem(CONST_SLOT_BACKPACK or 3) or nil
	local destinations = {}
	if pouch then
		destinations[#destinations + 1] = pouch
	end
	if bp and bp ~= pouch then
		destinations[#destinations + 1] = bp
	end
	if #destinations == 0 then
		return false, 0
	end

	local moved = false
	if item.moveTo then
		for _, dest in ipairs(destinations) do
			if item:moveTo(dest) == true then
				moved = true
				break
			end
		end
	end
	if not moved then
		return false, 0
	end
	creditLootStats(statsPlayer, itemId, count)
	return true, 0
end

local function peekRrIndex(leaderGuid, n)
	leaderGuid = tonumber(leaderGuid) or 0
	n = math.max(1, tonumber(n) or 1)
	local idx = rrCursorByLeader[leaderGuid] or 0
	return idx % n
end

local function advanceRr(leaderGuid, n)
	leaderGuid = tonumber(leaderGuid) or 0
	n = math.max(1, tonumber(n) or 1)
	local idx = rrCursorByLeader[leaderGuid] or 0
	rrCursorByLeader[leaderGuid] = (idx + 1) % n
end

--- Split corpse among party seats. Each seat → that member's account pouch + analyser credit.
function LootSplit.splitCorpse(monster, corpse, owner)
	if not LootSplitConfig or LootSplitConfig.ENABLED == false then
		return false
	end
	if not monster or not corpse or not owner then
		return false
	end

	local mType = monster.getType and monster:getType() or nil
	if mType and mType.isRewardBoss and mType:isRewardBoss() then
		return false
	end

	local party = owner.getParty and owner:getParty() or nil
	if not party then
		return false
	end

	if not autoLootEnabled(owner, false) then
		return false
	end

	local corpsePos = corpse.getPosition and corpse:getPosition() or monster:getPosition()
	local seats = LootSplit.seats(party, corpsePos, monster)
	local onExpedition = partyOnExpedition(party)
	if onExpedition then
		if #seats < 1 then
			return false
		end
	else
		if #seats < 2 then
			return false
		end
	end

	local leader = party.getLeader and party:getLeader() or owner
	local leaderGuid = leader and leader.getGuid and leader:getGuid() or 0
	local seatCount = #seats

	local items = collectCorpseItems(corpse)
	if #items == 0 then
		return false
	end

	local goldPool = 0
	local coinItems = {}
	local otherItems = {}
	for _, it in ipairs(items) do
		if isCoinItem(it) then
			local anyAccept = false
			for _, p in ipairs(seats) do
				if playerAcceptsItem(p, it) then
					anyAccept = true
					break
				end
			end
			if anyAccept then
				goldPool = goldPool + itemWorth(it)
				coinItems[#coinItems + 1] = it
			end
		else
			otherItems[#otherItems + 1] = it
		end
	end

	local goldSeatMembers = {}
	if goldPool > 0 and #coinItems > 0 then
		local probe = coinItems[1]
		for _, seatMember in ipairs(seats) do
			if playerAcceptsItem(seatMember, probe) then
				goldSeatMembers[#goldSeatMembers + 1] = seatMember
			end
		end
	end

	if #goldSeatMembers > 0 and goldPool > 0 then
		for _, it in ipairs(coinItems) do
			if it.remove then
				it:remove()
			end
		end

		local nGold = #goldSeatMembers
		local share = math.floor(goldPool / nGold)
		local remainder = goldPool - (share * nGold)
		local remainderSeatIdx = nil
		if remainder > 0 then
			local start = peekRrIndex(leaderGuid, seatCount)
			for offset = 0, seatCount - 1 do
				local idx = ((start + offset) % seatCount) + 1
				local seatMember = seats[idx]
				for gi, gm in ipairs(goldSeatMembers) do
					if gm == seatMember then
						remainderSeatIdx = gi
						advanceRr(leaderGuid, seatCount)
						break
					end
				end
				if remainderSeatIdx then
					break
				end
			end
		end

		local goldId = (LootSplitConfig and LootSplitConfig.GOLD_COIN_ID) or 3031
		for gi, seatMember in ipairs(goldSeatMembers) do
			local amount = share
			if remainderSeatIdx and gi == remainderSeatIdx then
				amount = amount + remainder
			end
			if amount > 0 then
				if seatMember.addMoney then
					seatMember:addMoney(amount)
				end
				local left = amount
				while left > 0 do
					local chunk = math.min(left, 100)
					creditLootStats(seatMember, goldId, chunk)
					left = left - chunk
				end
			end
		end
	end

	for _, it in ipairs(otherItems) do
		local start = peekRrIndex(leaderGuid, seatCount)
		local delivered = false
		for offset = 0, seatCount - 1 do
			local idx = ((start + offset) % seatCount) + 1
			local seatMember = seats[idx]
			if playerAcceptsItem(seatMember, it) then
				local function tryDeliver()
					if not seatCanCarry(seatMember, it) then
						return false
					end
					return select(1, deliverItem(seatMember, it, seatMember))
				end
				if tryDeliver() then
					rrCursorByLeader[leaderGuid] = (start + offset + 1) % seatCount
					delivered = true
					break
				end
				if ExpeditionSafety and ExpeditionSafety.handleShortage then
					local recovered = ExpeditionSafety.handleShortage(
						seatMember,
						"cap",
						tryDeliver,
						string.format("%s has insufficient capacity for loot. Expedition stopped.", seatMember:getName())
					)
					if recovered then
						rrCursorByLeader[leaderGuid] = (start + offset + 1) % seatCount
						delivered = true
						break
					end
				end
			end
		end
		if not delivered then
			-- leave on corpse for stock auto-loot / manual pick
		end
	end

	return true
end

function LootSplit.onDropLoot(monster, corpse)
	if not monster or not corpse then
		return
	end
	local owner = nil
	if corpse.getCorpseOwner then
		owner = Player(corpse:getCorpseOwner())
	end
	if not owner then
		return
	end
	IdleSafe.call("LootSplit.onDropLoot", function()
		local mType = monster.getType and monster:getType() or nil
		local isBoss = mType and mType.isRewardBoss and mType:isRewardBoss()
		trySellForInsufficientCap(owner, corpse, isBoss)
		LootSplit.splitCorpse(monster, corpse, owner)
	end)
end
