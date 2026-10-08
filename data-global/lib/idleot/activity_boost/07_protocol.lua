ActivityBoostProtocol = ActivityBoostProtocol or {}

ActivityBoostProtocol.send = IdleUtil.jsonSender(ActivityBoostConfig.OPCODE)

function ActivityBoostProtocol.sendState(player)
	if not player then
		return
	end
	local ok, err = pcall(function()
		ActivityBoostLedger.reconcileWithEngine(player)
		local fiendishHunt = ActivityBoostFiendishHunt.get(player) or nil
		local activities = ActivityBoostActivities.list(player, { fiendishHunt = fiendishHunt })
		local fragsToday = 0
		fragsToday = ActivityBoostActivities.getWorldBossFragsToday(player)
		local cap = tonumber(ActivityBoostConfig.WORLD_BOSS_DAILY_CAP) or 3
		ActivityBoostProtocol.send(player, {
			type = "state",
			boost = ActivityBoostLedger.getStatus(player),
			activities = activities,
			fiendishHunt = fiendishHunt,
			worldBoss = {
				active = ActivityBoostWorldBoss.listActive(),
				schedule = ActivityBoostWorldBoss.listSchedule(),
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

--- Kill-counter updates: activities + boost only (world boss schedule is most of the full state).
function ActivityBoostProtocol.sendProgress(player)
	if not player then
		return
	end
	local ok, err = pcall(function()
		ActivityBoostLedger.reconcileWithEngine(player)
		local fiendishHunt = ActivityBoostFiendishHunt.get(player) or nil
		ActivityBoostProtocol.send(player, {
			type = "progress",
			boost = ActivityBoostLedger.getStatus(player),
			activities = ActivityBoostActivities.list(player, { fiendishHunt = fiendishHunt }),
		})
	end)
	if not ok then
		logger.error("[ActivityBoost] sendProgress failed: {}", err)
	end
end

function ActivityBoostProtocol.handle(player, buffer)
	if not player then
		return
	end
	local data = JsonParser.decode(buffer) or nil
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
	if action == "joinFiendishHunt" then
		local ok, err = ActivityBoostFiendishHunt.join(player)
		if ok then
			ActivityBoostProtocol.sendState(player)
		else
			player:sendTextMessage(MESSAGE_FAILURE, err or "Cannot join Fiendish Hunt.")
			ActivityBoostProtocol.send(player, { type = "error", message = err or "Cannot join Fiendish Hunt." })
		end
		return
	end
end
