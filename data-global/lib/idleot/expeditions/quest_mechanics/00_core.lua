-- Auto-play quest mechanics for CIP Team Finder quest expeditions.
-- Mirror of ExpeditionBossMechanics: register(nameOrCipId, run) gates catalog emit.

ExpeditionQuestMechanics = ExpeditionQuestMechanics or {}
ExpeditionQuestMechanics.mechanics = ExpeditionQuestMechanics.mechanics or {}

function ExpeditionQuestMechanics.register(name, mechanic, opts)
	opts = opts or {}
	local key = tostring(name or ""):lower()
	if key == "" then
		return
	end
	ExpeditionQuestMechanics.mechanics[key] = {
		name = name,
		run = mechanic,
		opts = opts,
	}
end

function ExpeditionQuestMechanics.handles(key)
	if key == nil then
		return false
	end
	return ExpeditionQuestMechanics.mechanics[tostring(key):lower()] ~= nil
end

function ExpeditionQuestMechanics.start(session, key, ctx)
	local entry = ExpeditionQuestMechanics.mechanics[tostring(key or ""):lower()]
	if not entry or type(entry.run) ~= "function" then
		return false
	end
	ExpeditionQuestMechanics.stop(session)
	session._questMechanic = { key = key, entry = entry }
	local ok, err = pcall(entry.run, ctx or { session = session })
	if not ok then
		logger.error("[ExpeditionQuestMechanics] {}: start failed: {}", tostring(key), tostring(err))
		ExpeditionQuestMechanics.stop(session)
		return false
	end
	return true
end

function ExpeditionQuestMechanics.stop(session)
	if not session then
		return
	end
	session._questMechanic = nil
end
