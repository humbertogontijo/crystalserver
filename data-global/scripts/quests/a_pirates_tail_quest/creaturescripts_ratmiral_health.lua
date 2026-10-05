local ratmiralHealth = CreatureEvent("ratmiralHealth")

-- Keyed by Ratmiral creature id: private expedition instances run fights concurrently.
local hasRetreated = {}

function ratmiralHealth.onHealthChange(creature, attacker, primaryDamage, primaryType, secondaryDamage, secondaryType, origin)
	if not creature or not creature:getMonster() then
		return primaryDamage, primaryType, secondaryDamage, secondaryType
	end

	local creatureId = creature:getId()
	if creature:getHealth() > 110000 then
		hasRetreated[creatureId] = nil
	end

	local currentHealth = creature:getHealth() + primaryDamage

	if not hasRetreated[creatureId] and currentHealth <= 110000 then
		hasRetreated[creatureId] = true

		local ratticusSearchPos = Position(33917, 31350, 13)
		local catkillerSearchPos = Position(33891, 31352, 13)
		local ratticusChangePos = Position(33905, 31351, 14)
		local catkillerChangePos = Position(33903, 31350, 14)
		local rateyePos = Position(33905, 31350, 14)
		local instanceId = creature:getInstanceId()

		creature:say("JOIN ME, MY CREW!", TALKTYPE_MONSTER_SAY)

		addEvent(function()
			local ratticus = nil
			local catkiller = nil

			for _, mob in ipairs(Game.getSpectators(ratticusSearchPos, false, false, 10, 10, 10, 10, instanceId)) do
				if mob:getMonster() and mob:getName():lower() == "1st mate ratticus" then
					ratticus = mob
					break
				end
			end

			for _, mob in ipairs(Game.getSpectators(catkillerSearchPos, false, false, 10, 10, 10, 10, instanceId)) do
				if mob:getMonster() and mob:getName():lower() == "mister catkiller" then
					catkiller = mob
					break
				end
			end

			if ratticus then
				ratticus:setMoveLocked(false)
				ratticus:teleportTo(ratticusChangePos)
				ratticus:getPosition():sendMagicEffect(CONST_ME_TELEPORT)
			end

			if catkiller then
				catkiller:setMoveLocked(false)
				catkiller:teleportTo(catkillerChangePos)
				catkiller:getPosition():sendMagicEffect(CONST_ME_TELEPORT)
			end

			Game.createMonster("Rateye Ric", rateyePos, true, true, nil, instanceId)
		end, 500)
	end

	return primaryDamage, primaryType, secondaryDamage, secondaryType
end

ratmiralHealth:register()
