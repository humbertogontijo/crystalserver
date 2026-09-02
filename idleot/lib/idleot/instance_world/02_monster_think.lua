-- Instance-aware monster onThink wrapping.
--
-- Upstream quest monsters may register mType.onThink hooks that return true after
-- running custom logic (Rotten Blood hazard/area icons, future quest packs). In
-- Crystal that short-circuits Monster::onThink before searchTarget, movement, and
-- attacks. Open-world behavior is preserved; private instances (expeditions, home,
-- raids) re-run the quest hook then return false so engine AI continues.
--
-- Add new entries to QUEST_THINK_HOOKS when CrystalServer ships more quest hooks.

InstanceMonsterThink = InstanceMonsterThink or {}

-- Keep monster names aligned with rotten_blood_quest/startup_register_events.lua.
local ROTTEN_BLOOD_MONSTERS = {
	"sopping corpus",
	"oozing corpus",
	"mycobiontic beetle",
	"bloated man-maggot",
	"walking pillar",
	"darklight matter",
	"darklight source",
	"darklight striker",
	"darklight emitter",
	"darklight construct",
	"wandering pillar",
	"converter",
	"oozing carcass",
	"sopping carcass",
	"rotten man-maggot",
	"meandering mushroom",
}

local function inPrivateInstance(monster)
	if not monster or not monster.getInstanceId then
		return false
	end
	local instanceId = tonumber(monster:getInstanceId()) or 0
	return instanceId >= (InstanceWorld and InstanceWorld.PRIVATE_BASE or 3000000)
end

-- Private expedition hunts: rotten-blood icons use instance-aware logic (see 03_rotten_blood_icons.lua).
InstanceMonsterThink.QUEST_THINK_HOOKS = {
	{
		id = "rotten-blood",
		monsters = ROTTEN_BLOOD_MONSTERS,
		run = function(monster, interval)
			if inPrivateInstance(monster) then
				if RottenBloodInstanceIcons and RottenBloodInstanceIcons.onMonsterThink then
					RottenBloodInstanceIcons.onMonsterThink(monster)
				end
			elseif type(onRottenMonsterThink) == "function" then
				onRottenMonsterThink(monster, interval)
			end
		end,
	},
}

local function wrapMonsterThink(mType, runHook)
	-- Use mType.onThink assignment (revscriptsys) so eventType is set before loadCallback.
	mType.onThink = function(monster, interval)
		if runHook then
			runHook(monster, interval)
		end
		-- Open world: keep upstream short-circuit (return true). Instances: full AI.
		return not inPrivateInstance(monster)
	end
end

function InstanceMonsterThink.apply()
	local wrapped = 0
	for _, hook in ipairs(InstanceMonsterThink.QUEST_THINK_HOOKS) do
		for _, monsterName in ipairs(hook.monsters or {}) do
			local mType = MonsterType(monsterName)
			if not mType then
				logger.warn("[InstanceMonsterThink] {}: MonsterType '{}' not found", hook.id or "?", monsterName)
			else
				wrapMonsterThink(mType, hook.run)
				wrapped = wrapped + 1
			end
		end
	end
	if wrapped > 0 then
		logger.info("[InstanceMonsterThink] wrapped onThink for {} quest monsters", wrapped)
	end
end
