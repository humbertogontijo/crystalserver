LootSplit = LootSplit or {}

-- leaderGuid → next round-robin index (persists across kills so first item rotates).
local rrCursorByLeader = {}

local function pouchId()
	return (LootSplitConfig and LootSplitConfig.LOOT_POUCH_ID) or ITEM_GOLD_POUCH or 23721
end

function LootSplit.findLootPouch(player)
	if not player then
		return nil
	end
	local id = pouchId()
	local inboxSlot = CONST_SLOT_STORE_INBOX or 11
	local inbox = player.getStoreInbox and player:getStoreInbox() or player:getSlotItem(inboxSlot)
	if inbox and inbox.getSize then
		local size = inbox:getSize() or 0
		for i = 0, size - 1 do
			local it = inbox:getItem(i)
			if it and it:getId() == id then
				return it
			end
		end
	end
	if player.findItemInInbox then
		local pouch = player:findItemInInbox(id)
		if pouch then
			return pouch
		end
	end
	if player.getItemById then
		return player:getItemById(id, true)
	end
	return nil
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
	-- Binding missing (pre-rebuild): do not vacuum; leave for stock auto-loot.
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

local function resolveController(member)
	if not member then
		return nil
	end
	if TeamManager and TeamManager.isCompanion and TeamManager.isCompanion(member) then
		local ctrl = TeamManager.getCompanionController and TeamManager.getCompanionController(member)
		if ctrl then
			return ctrl
		end
	end
	return member
end

--- Filter probe uses the controller (companions inherit quick-loot via account sync).
local function seatAcceptsItem(seatMember, item)
	local ctrl = resolveController(seatMember) or seatMember
	return playerAcceptsItem(ctrl, item)
end

--- Capacity gate for the delivery controller (companions → leader pouch).
--- Returning false skips this seat so another party member with free cap can take it.
local function controllerCanCarry(destPlayer, item)
	if not destPlayer or not item then
		return false
	end
	if not destPlayer.getFreeCapacity or not item.getWeight then
		return true
	end
	local weight = tonumber(item:getWeight()) or 0
	if weight <= 0 then
		return true
	end
	return (tonumber(destPlayer:getFreeCapacity()) or 0) >= weight
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

--- RR wheel of actual party members (not collapsed controllers).
--- Companions stay as their own seats so sendLootStats can credit them; pouch
--- delivery still goes to resolveController(seat).
--- Returns seats, uniqueControllers (for multi-account gate), uniqueCount.
function LootSplit.seats(party, corpsePos, corpseCreature)
	if not party then
		return {}, {}, 0
	end
	if corpsePos and not partyClaimingCorpse(party, corpsePos) then
		return {}, {}, 0
	end

	local seats = {}
	local uniqueControllers = {}
	local byAccount = {}
	local uniqueCount = 0

	for _, member in ipairs(partyMembers(party)) do
		local controller = resolveController(member)
		local eligible = controller and controller.getAccountId and member
		if eligible and corpseCreature and not sameInstance(controller, corpseCreature) then
			eligible = false
		end
		-- Ranged supports stay eligible: proximity is only required for the party claim above.
		if eligible and corpseCreature and not sameInstance(member, corpseCreature) then
			eligible = false
		end
		if eligible then
			seats[#seats + 1] = member
			local accountId = controller:getAccountId() or 0
			if accountId > 0 and not byAccount[accountId] then
				byAccount[accountId] = true
				uniqueCount = uniqueCount + 1
				uniqueControllers[#uniqueControllers + 1] = controller
			end
		end
	end

	return seats, uniqueControllers, uniqueCount
end

--- Backward-compatible unique controllers (one per account).
function LootSplit.recipients(party, corpsePos, corpseCreature)
	local _, uniqueControllers = LootSplit.seats(party, corpsePos, corpseCreature)
	return uniqueControllers
end

local function collectCorpseItems(corpse)
	local items = {}
	if not corpse or not corpse.getSize then
		return items
	end
	local size = corpse:getSize() or 0
	-- Snapshot backwards so later removals do not invalidate indices.
	for i = size - 1, 0, -1 do
		local it = corpse:getItem(i)
		if it then
			-- getItem already tags containers with the Container metatable.
			if it.getSize and (it:getSize() or 0) > 0 then
				-- Nested bags: flatten leaf items only (same as C++ quick loot).
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
--- Solo hunts early-return from splitCorpse; without this, playerQuickLootCorpse
--- just leaves heavy loot on the corpse and never sells.
local function trySellForInsufficientCap(player, corpse, isBoss)
	if not player or not corpse then
		return false
	end
	if not RemoteHirelingEconomy or not RemoteHirelingEconomy.maybeSellForShortage then
		return false
	end
	local dest = resolveController(player) or player
	if not autoLootEnabled(dest, isBoss == true) then
		return false
	end
	if not dest.getFreeCapacity then
		return false
	end

	-- UI "0 oz" is freeCap < 100 (centioz). Do not depend on accepts/getWeight
	-- bindings here — C++ will leave loot on the corpse either way.
	local free = tonumber(dest:getFreeCapacity()) or 0
	if free < 100 then
		return RemoteHirelingEconomy.maybeSellForShortage(dest, "cap") == true
	end

	for _, it in ipairs(collectCorpseItems(corpse)) do
		if playerAcceptsItem(dest, it) and not controllerCanCarry(dest, it) then
			return RemoteHirelingEconomy.maybeSellForShortage(dest, "cap") == true
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
		pcall(function()
			player:sendLootStats(statsItem, count)
		end)
		if statsItem.remove then
			pcall(function()
				statsItem:remove()
			end)
		end
	end
end

--- Deliver to `destPlayer` (controller pouch); credit analyser to `statsPlayer` (seat).
--- Prefer C++ managed collect (category containers + capacity) so a full pouch on one
--- seat does not strand loot when another party member can still carry it.
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
		-- Player:addMoney respects autoBank (banks when enabled; else pouch/inventory).
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
			-- Binding present: trust managed collect (capacity + category containers).
			-- Do not fall through to raw moveTo — that can ignore capacity/room rules.
			if success == true then
				creditLootStats(statsPlayer, itemId, count)
				return true, 0
			end
			return false, 0
		end
		-- pcall failed (pre-rebuild / bad userdata): fall through to pouch move.
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

--- Split corpse by party seats. Pouch → controller; sendLootStats → seat member.
--- Leader + 2 companions + friend → pouches 3/4 vs 1/4; analyser 1/4 each name.
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

	-- Companions may own the corpse but fail party:addMember; always prefer the
	-- controlling primary for party lookup + auto-loot feature (mirrors C++ getAutoLootPlayer).
	local controller = resolveController(owner) or owner
	local party = controller.getParty and controller:getParty() or nil
	if not party and owner.getParty then
		party = owner:getParty()
	end
	if not party then
		return false
	end

	if not autoLootEnabled(controller, false) then
		return false
	end

	local corpsePos = corpse.getPosition and corpse:getPosition() or monster:getPosition()
	local seats, uniqueControllers, uniqueCount = LootSplit.seats(party, corpsePos, monster)
	local onExpedition = partyOnExpedition(party)
	if onExpedition then
		if #seats < 1 then
			return false
		end
	else
		if uniqueCount < 2 or #seats < 2 then
			return false
		end
	end

	local leader = party.getLeader and party:getLeader() or controller
	local leaderGuid = leader and leader.getGuid and leader:getGuid() or 0
	local seatCount = #seats

	local items = collectCorpseItems(corpse)
	if #items == 0 then
		return false
	end

	-- Gold pool: coins accepted by at least one unique controller.
	local goldPool = 0
	local coinItems = {}
	local otherItems = {}
	for _, it in ipairs(items) do
		if isCoinItem(it) then
			local anyAccept = false
			for _, p in ipairs(uniqueControllers) do
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

	-- Per-seat gold amounts: each accepting seat gets an equal share (1/N).
	-- Credit goes to the seat member; money goes to that seat's controller.
	local goldSeatMembers = {}
	if goldPool > 0 and #coinItems > 0 then
		local probe = coinItems[1]
		for _, seatMember in ipairs(seats) do
			if seatAcceptsItem(seatMember, probe) then
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
				local dest = resolveController(seatMember) or seatMember
				if dest.addMoney then
					dest:addMoney(amount)
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

	-- Round-robin non-coin items over seats; deliver to controller, stats to seat.
	-- On filter reject / no capacity / collect failure, try the next seat so loot is
	-- not stranded while another party member can still take it.
	for _, it in ipairs(otherItems) do
		local start = peekRrIndex(leaderGuid, seatCount)
		local delivered = false
		for offset = 0, seatCount - 1 do
			local idx = ((start + offset) % seatCount) + 1
			local seatMember = seats[idx]
			if seatAcceptsItem(seatMember, it) then
				local dest = resolveController(seatMember) or seatMember
				local function tryDeliver()
					if not controllerCanCarry(dest, it) then
						return false
					end
					return select(1, deliverItem(dest, it, seatMember))
				end
				if tryDeliver() then
					rrCursorByLeader[leaderGuid] = (start + offset + 1) % seatCount
					delivered = true
					break
				end
				-- Any collect miss (weight, pouch full, category room): sell pouch then retry.
				-- Abort still only when ExpeditionSafety finds an entered session + stop flag.
				if ExpeditionSafety and ExpeditionSafety.handleShortage then
					local recovered = ExpeditionSafety.handleShortage(
						dest,
						"cap",
						tryDeliver,
						string.format("%s has insufficient capacity for loot. Expedition stopped.", dest:getName())
					)
					if recovered then
						rrCursorByLeader[leaderGuid] = (start + offset + 1) % seatCount
						delivered = true
						break
					end
				end
			end
		end
		-- Undelivered items stay on the corpse for stock auto-loot / manual pick
		-- (highlight clears only when remaining items are filter-skipped for the owner).
		if not delivered then
			-- leave as-is
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
	pcall(function()
		-- Runs before async C++ playerQuickLootCorpse (same death tick, sync PostDropLoot).
		local mType = monster.getType and monster:getType() or nil
		local isBoss = mType and mType.isRewardBoss and mType:isRewardBoss()
		trySellForInsufficientCap(owner, corpse, isBoss)
		LootSplit.splitCorpse(monster, corpse, owner)
	end)
end
