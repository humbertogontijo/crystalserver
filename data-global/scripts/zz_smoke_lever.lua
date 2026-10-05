local smoke = GlobalEvent("ZzSmokeLever")

local function log(fmt, ...)
	logger.info("[SMOKE] " .. string.format(fmt, ...))
end

local function monstersIn(instanceId)
	local out = {}
	for _, m in ipairs(Game.getMonsters()) do
		if m:getInstanceId() == instanceId then
			out[#out + 1] = string.format("%s hp=%d/%d", m:getName(), m:getHealth(), m:getMaxHealth())
		end
	end
	return table.concat(out, ", ")
end

local function hit(instanceId, name)
	for _, m in ipairs(Game.getMonsters()) do
		if m:getInstanceId() == instanceId and m:getName() == name then
			doTargetCombatHealth(0, m, COMBAT_PHYSICALDAMAGE, -(m:getHealth() + 10), -(m:getHealth() + 10), CONST_ME_NONE)
			return true
		end
	end
	return false
end

function smoke.onStartup()
	addEvent(function()
		local ok, err = pcall(function()
			local lever = BossLever.get("Phosphorus")
			log("lever=%s chained=%s final=%s difficulty=%s", tostring(lever ~= nil), tostring(lever and lever:isChained()), tostring(lever and lever.finalBoss), tostring(lever and BossDifficulty.isEnabled(lever)))
			local catalog = ExpeditionConfig.getById(2826, "boss")
			log("catalog=%s bossLever=%s diffLever=%s", tostring(catalog ~= nil), tostring(ExpeditionConfig.bossLever(catalog) == lever), tostring(ExpeditionConfig.bossDifficultyLever(catalog) == lever))
			local spec = ExpeditionConfig.bossLeverInstanceSpec(catalog, lever)
			log("spec boundary=%d,%d %dx%d entry=%d,%d,%d floors=%d", spec.boundary.x, spec.boundary.y, spec.boundary.w, spec.boundary.h, spec.entry.x, spec.entry.y, spec.entry.z, #spec.floors)
			log("faceless=%s final=%s", tostring(BossLever.get("Faceless Bane") ~= nil), tostring(BossLever.forFinalBoss("Phosphorus (Final)") == lever))
			local instanceId = ExpeditionInstance.allocate()
			local instance = ExpeditionInstance.build(instanceId, spec, 1)
			log("instance=%s id=%s entry=%s", tostring(instance ~= nil), tostring(instanceId), instance and tostring(instance.entry) or "-")
			local okStart, spawned = lever:startEncounter({ instanceId = instanceId, difficulty = 10, playerIds = {} })
			log("startEncounter ok=%s spawned=%d world=[%s] inst=[%s]", tostring(okStart), #spawned, monstersIn(0):match("Phosphorus[^,]*") or "", monstersIn(instanceId))
			-- no players in the arena: movePlayers aborts the chain, so drive forms directly
			for _ = 1, 4 do
				hit(instanceId, "Phosphorus")
			end
			addEvent(function()
				log("after flee inst=[%s]", monstersIn(instanceId))
				local d = lever:spawnForm("Maior Domus (Final)", Position(33739, 32690, 15), instanceId)
				local m = lever:spawnForm("Mimar Haffar (Final)", Position(33747, 32690, 15), instanceId)
				log("forms inst=[%s] domusInst=%s", monstersIn(instanceId), tostring(d and d:getInstanceId()))
				for _, mon in ipairs({ d, m }) do
					if mon then
						mon:remove()
					end
				end
				lever:clearEncounter(instanceId)
				ExpeditionInstance.teardown(instance)
				log("done")
			end, 1000)
		end)
		if not ok then
			log("ERROR %s", tostring(err))
		end
	end, 5000)
	return true
end

smoke:register()
