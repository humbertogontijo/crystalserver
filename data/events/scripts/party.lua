function Party:onJoin(player)
	local playerUid = player:getGuid()
	addEvent(function(playerFuncUid)
		local playerEvent = Player(playerFuncUid)
		if not playerEvent then
			return
		end
		local party = playerEvent:getParty()
		if not party then
			return
		end
		party:refreshHazard()
	end, 100, playerUid)
	return true
end

function Party:onLeave(player)
	local playerUid = player:getGuid()
	local members = self:getMembers()
	table.insert(members, self:getLeader())
	local memberUids = {}
	for _, member in ipairs(members) do
		if member:getGuid() ~= playerUid then
			table.insert(memberUids, member:getGuid())
		end
	end

	addEvent(function(playerFuncUid, memberUidsTableEvent)
		local playerEvent = Player(playerFuncUid)
		if playerEvent then
			playerEvent:updateHazard()
		end

		for _, memberUid in ipairs(memberUidsTableEvent) do
			local member = Player(memberUid)
			if member then
				local party = member:getParty()
				if party then
					party:refreshHazard()
					return -- Only one player needs to refresh the hazard for the party
				end
			end
		end
	end, 100, playerUid, memberUids)
	return true
end

function Party:onDisband()
	local members = self:getMembers()
	local leader = self:getLeader()
	if leader then
		table.insert(members, leader)
	end

	local memberIds = {}
	for _, member in ipairs(members) do
		if member and member:getId() then
			table.insert(memberIds, member:getId())
		end
	end

	addEvent(function()
		for _, memberId in ipairs(memberIds) do
			local member = Player(memberId)
			if member then
				member:updateHazard()
			end
		end
	end, 100)
	return true
end

local partyVocationBonus = {
	[1] = 1.20, -- same vocation: +20%
	[2] = 1.35, -- 2 different vocations: +35%
	[3] = 1.70, -- 3 different vocations: +70%
	[4] = 2.00, -- 4 different vocations: +100%
}

--- Companions count fully toward vocation diversity. Party share is
--- (weight / partySize) * ((vocBonus - 1) / (maxVocBonus - 1)) so that
--- 1 real + 3 companions at +100% => 2.5/4 * 100% = 62.5% each.
function Party:onShareExperience(exp)
	local uniqueVocationsCount = self:getUniqueVocationsCount()
	local partySize = self:getMemberCount() + 1

	if uniqueVocationsCount > 4 then
		uniqueVocationsCount = 4
	end

	local sharedExperienceMultiplier = partyVocationBonus[uniqueVocationsCount] or 1
	local realCount = 0
	local companionCount = 0
	local function countMember(member)
		if not member then
			return
		end
		if TeamManager and TeamManager.isCompanion and TeamManager.isCompanion(member) then
			companionCount = companionCount + 1
		else
			realCount = realCount + 1
		end
	end
	countMember(self:getLeader())
	for _, member in ipairs(self:getMembers() or {}) do
		countMember(member)
	end
	if realCount + companionCount ~= partySize then
		realCount = math.max(0, partySize - companionCount)
	end
	local weight = realCount + 0.5 * companionCount
	if partySize < 1 then
		partySize = 1
	end
	local maxVocBonus = partyVocationBonus[4] or 2.00
	local bonusFactor = (sharedExperienceMultiplier - 1) / math.max(0.0001, maxVocBonus - 1)
	local sharedExp = exp * (weight / partySize) * bonusFactor
	-- No vocation bonus: equal split of raw exp (stock used multiplier 1).
	if sharedExperienceMultiplier <= 1 then
		sharedExp = exp / partySize
	end

	return math.ceil(sharedExp)
end
