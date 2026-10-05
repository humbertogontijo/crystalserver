QuestsProtocol = QuestsProtocol or {}

function QuestsProtocol.send(player, payload)
	if not player or not QuestsConfig then
		return
	end
	player:sendExtendedOpcode(QuestsConfig.OPCODE, JsonParser.encode(payload))
end

local function resolveQuestTarget(controller, nameOrGuid, requireOnline)
	if not controller then
		return nil, "Invalid player."
	end
	if not nameOrGuid or nameOrGuid == "" then
		return controller
	end
	if tostring(nameOrGuid):lower() == controller:getName():lower() then
		return controller
	end
	if not Alts or not Alts.resolveAccountMember then
		return nil, "Alt quests require alts support."
	end
	if requireOnline and Alts.ensureOnlineMember then
		local online, onlineErr = Alts.ensureOnlineMember(controller, nameOrGuid)
		if not online then
			return nil, onlineErr or "Character must be online."
		end
		return online
	end
	local target, err = Alts.resolveAccountMember(controller, nameOrGuid)
	if not target then
		return nil, err or "Unknown character."
	end
	return target
end

function QuestsProtocol.sendList(player, kind, targetName)
	local target, err = resolveQuestTarget(player, targetName, false)
	if not target then
		QuestsProtocol.send(player, { type = "error", message = err or "Failed to resolve character." })
		return
	end
	QuestsProtocol.send(player, {
		type = "list",
		kind = kind or "all",
		targetName = target:getName(),
		entries = QuestsManager.listForPlayer(target, kind ~= "all" and kind or nil),
	})
end

function QuestsProtocol.handle(player, buffer)
	local data = JsonParser.decode(buffer)
	if type(data) ~= "table" then
		return
	end
	local action = data.action
	local targetName = data.name
	if action == "list" then
		QuestsProtocol.sendList(player, data.kind or "all", targetName)
		return
	end
	local target, resolveErr = resolveQuestTarget(player, targetName, true)
	if not target then
		QuestsProtocol.send(player, { type = "error", message = resolveErr or "Failed to resolve character." })
		return
	end
	if action == "accept" then
		local ok, msg = QuestsManager.accept(target, data.id)
		if ok then
			player:sendTextMessage(MESSAGE_EVENT_ADVANCE, msg or "Accepted.")
			QuestsProtocol.send(player, { type = "ok", action = "accept", id = data.id, message = msg })
			QuestsProtocol.sendList(player, data.kind or "all", targetName)
		else
			player:sendTextMessage(MESSAGE_FAILURE, msg or "Failed.")
			QuestsProtocol.send(player, { type = "error", message = msg or "Failed." })
		end
		return
	end
	if action == "report" then
		local ok, msg, bossHuntId = QuestsManager.report(target, data.id, {
			rewardUid = data.rewardUid,
		})
		if ok then
			player:sendTextMessage(MESSAGE_EVENT_ADVANCE, msg or "Reported.")
			QuestsProtocol.send(player, {
				type = "ok",
				action = "report",
				id = data.id,
				message = msg,
				bossHuntId = bossHuntId,
			})
			QuestsProtocol.sendList(player, data.kind or "all", targetName)
			if bossHuntId then
				-- Refresh exclusive solo bosses into the client's expedition catalog.
				ExpeditionProtocol.sendCatalog(player)
				QuestsProtocol.send(player, {
					type = "hunt",
					id = data.id,
					huntId = bossHuntId,
					huntHint = nil,
				})
			end
		else
			player:sendTextMessage(MESSAGE_FAILURE, msg or "Failed.")
			QuestsProtocol.send(player, { type = "error", message = msg or "Failed." })
		end
		return
	end
	if action == "hunt" then
		local entry = QuestsCatalog.get(data.id)
		if not entry then
			QuestsProtocol.send(player, { type = "error", message = "Unknown quest." })
			return
		end
		local huntId = nil
		local huntHint = entry.huntHint
		-- After report, prefer exclusive Paw & Fur solo boss when unlocked.
		if entry.handler == "kitno" and entry.bossName and QuestsKitnoBoss then
			local bossId = QuestsKitnoBoss.expeditionIdForTaskId(entry.taskId)
			if bossId and QuestsKitnoBoss.isUnlocked(target, bossId) then
				huntId = bossId
				huntHint = QuestsKitnoBoss.resolveMonsterName(entry.bossName) or entry.bossName
			end
		end
		if entry.handler == "arena" and QuestArena and QuestArena.expeditionIdForArena then
			huntId = QuestArena.expeditionIdForArena(entry.arenaId)
			huntHint = entry.huntHint
			-- Fee-paid exclusive rows only appear after accept; refresh client catalog.
			ExpeditionProtocol.sendCatalog(player)
		end
		if not huntId and ExpeditionConfig and ExpeditionConfig.Catalog then
			local hint = entry.huntHint
			if hint then
				local needle = tostring(hint):lower()
				for _, cat in ipairs(ExpeditionConfig.Catalog) do
					if not cat.exclusiveKitno and not cat.exclusiveArena then
						local name = tostring(cat.name or ""):lower()
						if name == needle or name:find(needle, 1, true) then
							huntId = cat.id
							break
						end
					end
				end
			end
		end
		QuestsProtocol.send(player, {
			type = "hunt",
			id = data.id,
			huntId = huntId,
			huntHint = huntHint,
		})
	end
end
