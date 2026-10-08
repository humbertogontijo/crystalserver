-- Grand Master Oberon (The Secret Library): at 20% health (three times) he heals, calls a
-- falcon knight/paladin and turns immune (creature event OberonImmunity) after shouting a
-- taunt; a player near him must say the matching retort. The party member closest to him
-- answers with the stock retort for the taunt he shouted; with nobody in earshot, the
-- closest one walks up to him first.
--
-- Oberon hears every player line (spell words included) and ignores all of them for the
-- next 1-2s after each one, so the party's own casts would drown the retort: his hearing
-- exhaust is cleared right before the answer, as a player timing it between casts would.

local IMMUNE_EVENT = "OberonImmunity"
local ANSWER_INTERVAL_MS = 2500
local HEARING_RANGE = 7
local APPROACH_RANGE = 4

ExpeditionBossMechanics.register("Grand Master Oberon", function(ctx)
	ctx:whileBossHasEvent(IMMUNE_EVENT, ANSWER_INTERVAL_MS, function(boss)
		local storage = GrandMasterOberonConfig.Storage
		local retort = GrandMasterOberonResponses[boss:getStorageValue(storage.Asking)]
		if not retort then
			return
		end
		local bossPos = boss:getPosition()
		local speaker = ctx:nearestPlayer(bossPos, HEARING_RANGE)
		if speaker then
			boss:setStorageValue(storage.Exhaust, 0)
			speaker:say(retort.msg, TALKTYPE_SAY)
			return
		end
		local walker = ctx:nearestAgent(bossPos)
		if walker and not PlayerErrand.owns(walker) then
			ctx:walkTo(walker, bossPos, { reach = APPROACH_RANGE })
		end
	end)
end, { immunity = { IMMUNE_EVENT } })
