-- Echo Raid achievements, appended after the stock table in data/scripts/lib/register_achievements.lua.
-- Ids are persisted on players; if upstream claims them, move these and migrate.
local ECHO_RAID_ACHIEVEMENTS = {
	[584] = { name = "Echo Raid Initiate", grade = 1, points = 1, description = "You released your first Echo Raid and faced whatever the past remembered." },
	[585] = { name = "Echo Raid Hunter", grade = 1, points = 2, description = "You have defeated Echo Wardens of ten different creature kinds." },
	[586] = { name = "Echo Raid Walker", grade = 2, points = 4, description = "Twenty-five Echo Warden first-kills — the echoes know your name." },
	[587] = { name = "Echo Raid Conqueror", grade = 3, points = 6, description = "Fifty Echo Warden first-kills. Few hunters leave so many echoes silent." },
}

for id, achievement in pairs(ECHO_RAID_ACHIEVEMENTS) do
	if ACHIEVEMENTS[id] then
		logger.error("[EchoWarden] achievement id {} already taken by '{}'", id, ACHIEVEMENTS[id].name)
	else
		ACHIEVEMENTS[id] = achievement
		Game.registerAchievement(id, achievement.name, achievement.description, false, achievement.grade, achievement.points)
	end
end
ACHIEVEMENT_LAST = #ACHIEVEMENTS
