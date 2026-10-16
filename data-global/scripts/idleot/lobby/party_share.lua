-- Party shared XP. The vocation bonus scales linearly from 20% (one vocation)
-- to the full kill (all four). Companions take the same share as the character
-- that deployed them. A VIP account then adds 10% per distinct VIP account in
-- the party, up to 40% (see the gain callback). Rescales the stock
-- Party:onShareExperience result, ceil(exp * bonus / partySize).
local VOCATION_BONUS = { 1.20, 1.35, 1.70, 2.00 }
local MAX_BONUS = VOCATION_BONUS[#VOCATION_BONUS]
local BONUS_PER_ACCOUNT = 0.10
local MAX_PAID_ACCOUNTS = 4

local share = EventCallback("LobbyPartyShareExperience")

function share.partyOnShareExperience(party, exp)
	local vocations = math.min(party:getUniqueVocationsCount(), #VOCATION_BONUS)
	local bonus = VOCATION_BONUS[vocations]
	if not bonus then
		return exp
	end

	local partySize = party:getMemberCount() + 1
	local raw = exp * partySize / bonus
	return math.ceil(raw * (bonus - 1) / (MAX_BONUS - 1))
end

share:register()

local function paidAccountCount(party)
	local seen = {}
	local count = 0
	local function consider(member)
		if not member or not member:isVip() then
			return
		end
		local accountId = member:getAccountId()
		if not accountId or accountId <= 0 or seen[accountId] then
			return
		end
		seen[accountId] = true
		count = count + 1
	end

	consider(party:getLeader())
	for _, member in ipairs(party:getMembers()) do
		consider(member)
	end
	if count > MAX_PAID_ACCOUNTS then
		return MAX_PAID_ACCOUNTS
	end
	return count
end

--- 10% for a VIP playing alone. In a shared party, 10% per distinct VIP account (max 40%).
local gain = EventCallback("LobbyPartyPremiumExperience")

function gain.playerOnGainExperience(player, _target, exp, _rawExp)
	if not player:isVip() then
		return exp
	end

	local accounts = 1
	local party = player:getParty()
	if party and party:isSharedExperienceActive() and party:isSharedExperienceEnabled() then
		accounts = paidAccountCount(party)
		if accounts < 1 then
			accounts = 1
		end
	end
	return math.ceil(exp * (1 + BONUS_PER_ACCOUNT * accounts))
end

gain:register()
