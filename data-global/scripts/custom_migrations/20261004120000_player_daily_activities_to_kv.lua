-- IdleOT: daily activity counters moved from `player_daily_activities` to player KV
-- (activity-boost.counts). Today's rows are copied; older days would reset anyway.
local ACTIVITIES = { "daily_hunt", "solo_boss", "world_boss", "bounty_hunter", "fiendish_hunt" }

local m = Migration("20261004120000_player_daily_activities_to_kv")
function m:onExecute()
	local exists = db.storeQuery("SHOW TABLES LIKE 'player_daily_activities'")
	if not exists then
		return true
	end
	Result.free(exists)

	local today = os.date("%Y-%m-%d")
	local copied = 0
	local rows = db.storeQuery("SELECT * FROM `player_daily_activities` WHERE `activity_day` = " .. db.escapeString(today))
	if rows then
		repeat
			local guid = Result.getNumber(rows, "player_id")
			local store = KV.scoped("player"):scoped(tostring(guid)):scoped("activity-boost")
			if store:get("activityDay") == today then
				local counts = store:scoped("counts")
				for _, activityId in ipairs(ACTIVITIES) do
					local value = Result.getNumber(rows, activityId)
					if value and value > 0 then
						counts:set(activityId, value)
					end
				end
				copied = copied + 1
			end
		until not Result.next(rows)
		Result.free(rows)
	end

	db.query("DROP TABLE `player_daily_activities`")
	logger.info("player_daily_activities: copied {} rows to KV and dropped the table", copied)
	return true
end
m:register()
