ActivityBoostProtocol = ActivityBoostProtocol or {}

function ActivityBoostProtocol.send(player, payload)
	if not player or not ActivityBoostConfig then
		return false
	end
	local encoded = ExpeditionJson and ExpeditionJson.encode and ExpeditionJson.encode(payload) or nil
	if not encoded then
		return false
	end
	return player:sendExtendedOpcode(ActivityBoostConfig.OPCODE, encoded)
end

function ActivityBoostProtocol.sendState(player)
	if not player then
		return
	end
	local ok, err = pcall(function()
		ActivityBoostLedger.reconcileWithEngine(player)
		local activities = ActivityBoostActivities.list(player)
		local fragsToday = 0
		if ActivityBoostActivities and ActivityBoostActivities.getWorldBossFragsToday then
			fragsToday = ActivityBoostActivities.getWorldBossFragsToday(player)
		end
		local cap = tonumber(ActivityBoostConfig.WORLD_BOSS_DAILY_CAP) or 3
		ActivityBoostProtocol.send(player, {
			type = "state",
			boost = ActivityBoostLedger.getStatus(player),
			activities = activities,
			soloBoss = ActivityBoostSoloBoss.get(player),
			worldBoss = {
				active = ActivityBoostWorldBoss.listActive(),
				schedule = ActivityBoostWorldBoss.listSchedule(),
				bosses = ActivityBoostWorldBoss.listBossTimetable(),
				worldBossFragsToday = fragsToday,
				fraggedToday = fragsToday >= cap,
				sessionTimes = ActivityBoostConfig.WORLD_BOSS_SESSION_TIMES or {},
				bands = ActivityBoostConfig.LEVEL_BANDS or {},
			},
		})
	end)
	if not ok then
		logger.error("[ActivityBoost] sendState failed: {}", err)
	end
end

function ActivityBoostProtocol.handle(player, buffer)
	if not player then
		return
	end
	local data = ExpeditionJson and ExpeditionJson.decode and ExpeditionJson.decode(buffer) or nil
	if type(data) ~= "table" then
		return
	end
	local action = data.action
	if action == "getState" or action == "list" then
		ActivityBoostProtocol.sendState(player)
		return
	end
	if action == "joinWorldBoss" then
		local ok, err = ActivityBoostWorldBoss.join(player, data.band, data.boss or data.bossName)
		if ok then
			ActivityBoostProtocol.sendState(player)
		else
			player:sendTextMessage(MESSAGE_FAILURE, err or "Cannot join world boss.")
			ActivityBoostProtocol.send(player, { type = "error", message = err or "Cannot join world boss." })
		end
		return
	end
	if action == "leaveWorldBoss" then
		ActivityBoostWorldBoss.leave(player)
		ActivityBoostProtocol.sendState(player)
		return
	end
	if action == "startBossRush" then
		local solo = ActivityBoostSoloBoss.get(player)
		if not solo or not solo.expeditionId then
			ActivityBoostProtocol.send(player, { type = "error", message = "No Boss Rush assigned." })
			return
		end
		local can, err = ActivityBoostSoloBoss.canJoin(player, solo.expeditionId)
		if not can then
			player:sendTextMessage(MESSAGE_FAILURE, err or "Boss Rush unavailable.")
			ActivityBoostProtocol.send(player, { type = "error", message = err })
			return
		end
		ActivityBoostSoloBoss.markAttempt(player, solo.expeditionId)
		ActivityBoostProtocol.send(player, {
			type = "bossRushStart",
			expeditionId = solo.expeditionId,
			name = solo.name,
		})
		return
	end
end
