LootSplit = LootSplit or {}

-- leaderGuid → next weighted-wheel cursor (persists across kills).
local rrCursorByLeader = {}

LootSplit.providers = LootSplit.providers or {}

function LootSplit.findLootPouch(player)
	if not player then
		return nil
	end
	return player:getLootPouch()
end

--- Lobby weight table (guid → number). Missing/nil → equal weight 1 for every seat.
function LootSplit.providers.lobby(seats, ctx)
	local weights = {}
	local overrides = nil
	local owner = ctx and ctx.owner
	if owner and LobbyStore and LobbyStore.getForPlayer then
		local record = LobbyStore.getForPlayer(owner)
		overrides = record and LobbyStore.lootWeights(record) or nil
	end
	for _, seat in ipairs(seats or {}) do
		local guid = seat and seat:getGuid() or 0
		local w = 1
		if overrides then
			local raw = overrides[tostring(guid)]
			if raw == nil then
				raw = overrides[guid]
			end
			if raw ~= nil then
				w = tonumber(raw) or 0
			end
		end
		if w < 0 then
			w = 0
		end
		weights[guid] = w
	end
	return weights
end

function LootSplit.seatWeights(seats, ctx)
	local name = (LootSplitConfig and LootSplitConfig.weightProvider) or "lobby"
	local provider = LootSplit.providers[name] or LootSplit.providers.lobby
	return provider(seats, ctx or {})
end

local function weightOf(weights, seat)
	if not seat then
		return 0
	end
	return tonumber(weights[seat:getGuid()]) or 0
end

local function totalWeight(seats, weights)
	local total = 0
	for _, seat in ipairs(seats or {}) do
		total = total + weightOf(weights, seat)
	end
	return total
end

--- Weighted round-robin: walk a virtual wheel (seat i appears weight_i times).
--- Returns seat, nextCursor. Skips zero-weight seats.
function LootSplit.pickSeat(seats, weights, cursor)
	local total = totalWeight(seats, weights)
	if total <= 0 or not seats or #seats == 0 then
		return nil, cursor or 0
	end
	cursor = (tonumber(cursor) or 0) % total
	local acc = 0
	for _, seat in ipairs(seats) do
		local w = weightOf(weights, seat)
		if w > 0 then
			if cursor < acc + w then
				return seat, (cursor + 1) % total
			end
			acc = acc + w
		end
	end
	return seats[1], (cursor + 1) % total
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
	return tonumber(item:getWorth()) or 0
end

local function playerAcceptsItem(player, item)
	if not player or not item then
		return false
	end
	local ok, accepted = pcall(function()
		return player:acceptsQuickLootItem(item)
	end)
	if ok then
		return accepted == true
	end
	return false
end

local function autoLootEnabled(player, isBoss)
	if not player or not Features or not Features.AutoLoot then
		return false
	end
	if not configManager.getBoolean(configKeys.AUTOLOOT) then
		return false
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
	if not a or not b then
		return true
	end
	return a:getInstanceId() == b:getInstanceId()
end

local function inRange(corpsePos, player)
	if not corpsePos or not player then
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
	local leader = party:getLeader()
	if leader then
		members[#members + 1] = leader
	end
	local list = party:getMembers() or {}
	for _, m in ipairs(list) do
		if m then
			members[#members + 1] = m
		end
	end
	return members
end

local function partyOnExpedition(party)
	if not party then
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

--- Party-member seats only. Each seat delivers to that member's pouch.
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
	if not corpse then
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

local function trySellForInsufficientCap(player, corpse, isBoss)
	if not player or not corpse then
		return false
	end
	if not autoLootEnabled(player, isBoss == true) then
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
	if not player or not itemId or count <= 0 then
		return
	end
	local statsItem = Game.createItem(itemId, count)
	if statsItem then
		player:sendLootStats(statsItem, count)
		statsItem:remove()
	end
end

--- Deliver to seat member's pouch; credit analyser to the same seat.
local function deliverItem(destPlayer, item, statsPlayer)
	if not destPlayer or not item then
		return false, 0
	end
	statsPlayer = statsPlayer or destPlayer
	local itemId = item:getId()
	local count = item:getCount() or 1
	local worth = itemWorth(item)

	if isCoinItem(item) and worth > 0 then
		item:remove()
		destPlayer:addMoney(worth)
		local goldId = (LootSplitConfig.GOLD_COIN_ID) or 3031
		local remaining = worth
		while remaining > 0 do
			local chunk = math.min(remaining, 100)
			creditLootStats(statsPlayer, goldId, chunk)
			remaining = remaining - chunk
		end
		return true, worth
	end

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

	local pouch = LootSplit.findLootPouch(destPlayer)
	local bp = destPlayer:getSlotItem(CONST_SLOT_BACKPACK)
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
	for _, dest in ipairs(destinations) do
		if item:moveTo(dest) == true then
			moved = true
			break
		end
	end
	if not moved then
		return false, 0
	end
	creditLootStats(statsPlayer, itemId, count)
	return true, 0
end

--- Split corpse among party seats using weighted RR / proportional gold.
function LootSplit.splitCorpse(monster, corpse, owner)
	if LootSplitConfig.ENABLED == false then
		return false
	end
	if not monster or not corpse or not owner then
		return false
	end

	local mType = monster:getType()
	if mType and mType:isRewardBoss() then
		return false
	end

	local party = owner:getParty()
	if not party then
		return false
	end

	if not autoLootEnabled(owner, false) then
		return false
	end

	local corpsePos = corpse:getPosition() or monster:getPosition()
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

	local leader = party:getLeader() or owner
	local leaderGuid = leader and leader:getGuid() or 0
	local weights = LootSplit.seatWeights(seats, { owner = owner, leader = leader, party = party, monster = monster })
	local wheelTotal = totalWeight(seats, weights)
	if wheelTotal <= 0 then
		return false
	end

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
				if weightOf(weights, p) > 0 and playerAcceptsItem(p, it) then
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
	local goldWeights = {}
	local goldWeightTotal = 0
	if goldPool > 0 and #coinItems > 0 then
		local probe = coinItems[1]
		for _, seatMember in ipairs(seats) do
			local w = weightOf(weights, seatMember)
			if w > 0 and playerAcceptsItem(seatMember, probe) then
				goldSeatMembers[#goldSeatMembers + 1] = seatMember
				goldWeights[seatMember:getGuid()] = w
				goldWeightTotal = goldWeightTotal + w
			end
		end
	end

	if #goldSeatMembers > 0 and goldPool > 0 and goldWeightTotal > 0 then
		for _, it in ipairs(coinItems) do
			it:remove()
		end

		local distributed = 0
		local shares = {}
		for _, seatMember in ipairs(goldSeatMembers) do
			local w = goldWeights[seatMember:getGuid()] or 0
			local amount = math.floor(goldPool * w / goldWeightTotal)
			shares[seatMember:getGuid()] = amount
			distributed = distributed + amount
		end
		local remainder = goldPool - distributed
		if remainder > 0 then
			local cursor = rrCursorByLeader[leaderGuid] or 0
			local seat, nextCursor = LootSplit.pickSeat(goldSeatMembers, goldWeights, cursor)
			rrCursorByLeader[leaderGuid] = nextCursor
			if seat then
				shares[seat:getGuid()] = (shares[seat:getGuid()] or 0) + remainder
			end
		end

		local goldId = (LootSplitConfig.GOLD_COIN_ID) or 3031
		for _, seatMember in ipairs(goldSeatMembers) do
			local amount = shares[seatMember:getGuid()] or 0
			if amount > 0 then
				seatMember:addMoney(amount)
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
		local cursor = rrCursorByLeader[leaderGuid] or 0
		local delivered = false
		-- Try up to wheelTotal picks so zero-weight / full seats can be skipped fairly.
		for _ = 1, wheelTotal do
			local seatMember, nextCursor = LootSplit.pickSeat(seats, weights, cursor)
			cursor = nextCursor
			if not seatMember then
				break
			end
			if playerAcceptsItem(seatMember, it) then
				local function tryDeliver()
					if not seatCanCarry(seatMember, it) then
						return false
					end
					return select(1, deliverItem(seatMember, it, seatMember))
				end
				if tryDeliver() then
					rrCursorByLeader[leaderGuid] = cursor
					delivered = true
					break
				end
				local recovered = ExpeditionSafety.handleShortage(
					seatMember,
					"cap",
					tryDeliver,
					string.format("%s has insufficient capacity for loot. Expedition stopped.", seatMember:getName())
				)
				if recovered then
					rrCursorByLeader[leaderGuid] = cursor
					delivered = true
					break
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
	owner = Player(corpse:getCorpseOwner())
	if not owner then
		return
	end
	IdleSafe.call("LootSplit.onDropLoot", function()
		local mType = monster:getType()
		local isBoss = mType and mType:isRewardBoss()
		trySellForInsufficientCap(owner, corpse, isBoss)
		LootSplit.splitCorpse(monster, corpse, owner)
	end)
end
