-- Party shared XP: alts weigh half and the vocation bonus scales linearly
-- from 20% (one vocation) to full exp (all four), e.g. 1 real + 3 alts with
-- four vocations => 2.5/4 = 62.5% each. Rescales the stock Party:onShareExperience
-- result, ceil(exp * bonus / partySize), using the same bonus table.
local VOCATION_BONUS = { 1.20, 1.35, 1.70, 2.00 }
local MAX_BONUS = VOCATION_BONUS[#VOCATION_BONUS]

local callback = EventCallback("LobbyPartyShareExperience")

function callback.partyOnShareExperience(party, exp)
	local bonus = VOCATION_BONUS[math.min(party:getUniqueVocationsCount(), #VOCATION_BONUS)]
	if not bonus then
		return exp
	end

	local partySize = party:getMemberCount() + 1
	local alts = 0
	for _, member in ipairs(party:getMembers()) do
		if Alts.isCompanion(member) then
			alts = alts + 1
		end
	end
	local leader = party:getLeader()
	if leader and Alts.isCompanion(leader) then
		alts = alts + 1
	end

	local weight = (partySize - 0.5 * alts) / partySize
	local baseShare = exp * partySize / bonus
	return math.ceil(baseShare * weight * (bonus - 1) / (MAX_BONUS - 1))
end

callback:register()
