-- Boss difficulty owned by the BossLever config (`difficulty = { max, hpPerLevel, dmgPerLevel }`).
-- Only levers that declare it open the native 0x2F dialog; the reply arrives as
-- playerOnBossDifficulty (scripts/idleot/expeditions/events.lua). Clearing difficulty D
-- unlocks D + 1.
BossDifficulty = BossDifficulty or {}

BossDifficulty.DEFAULTS = {
	max = 25,
	hpPerLevel = 0.04,
	dmgPerLevel = 0.03,
}

BossDifficulty.KV_SCOPE = "boss.difficulty"

local pendingByPlayerId = {}

--- Merged difficulty config of a lever, or nil when the lever has none.
function BossDifficulty.config(lever)
	if not lever or type(lever.difficulty) ~= "table" then
		return nil
	end
	local cfg = {}
	for k, v in pairs(BossDifficulty.DEFAULTS) do
		cfg[k] = v
	end
	for k, v in pairs(lever.difficulty) do
		cfg[k] = v
	end
	cfg.max = math.max(0, math.floor(tonumber(cfg.max) or BossDifficulty.DEFAULTS.max))
	return cfg
end

function BossDifficulty.isEnabled(lever)
	return BossDifficulty.config(lever) ~= nil
end

function BossDifficulty.max(lever)
	local cfg = BossDifficulty.config(lever)
	return cfg and cfg.max or 0
end

function BossDifficulty.normalize(lever, value)
	local n = math.floor(tonumber(value) or 0)
	return math.max(0, math.min(BossDifficulty.max(lever), n))
end

--- Bosstiary race id of the lever boss (dialog creature + unlock key).
function BossDifficulty.raceId(lever)
	local mType = lever and MonsterType(lever.name)
	if not mType then
		return 0
	end
	local id = tonumber(mType:bossRaceId()) or 0
	if id <= 0 then
		id = tonumber(mType:raceId()) or 0
	end
	return id
end

function BossDifficulty.personalMax(player, lever)
	if not player or not lever then
		return 0
	end
	local ok, unlocked = pcall(function()
		return tonumber(player:kv():scoped(BossDifficulty.KV_SCOPE):get(tostring(BossDifficulty.raceId(lever))))
	end)
	if not ok then
		return 0
	end
	return BossDifficulty.normalize(lever, unlocked or 0)
end

--- Highest difficulty every human in `players` has unlocked (companions follow their owner).
function BossDifficulty.groupMax(players, lever)
	local best = nil
	for _, p in ipairs(players or {}) do
		local skip = (Alts.isCompanion(p)) or p:isHeadless()
		if not skip then
			local unlocked = BossDifficulty.personalMax(p, lever)
			if not best or unlocked < best then
				best = unlocked
			end
		end
	end
	return best or 0
end

function BossDifficulty.unlock(player, lever, difficulty)
	if not player or not BossDifficulty.isEnabled(lever) then
		return
	end
	local D = BossDifficulty.normalize(lever, difficulty)
	local nextLevel = math.min(BossDifficulty.max(lever), D + 1)
	if nextLevel > BossDifficulty.personalMax(player, lever) then
		player:kv():scoped(BossDifficulty.KV_SCOPE):set(tostring(BossDifficulty.raceId(lever)), nextLevel)
	end
end

function BossDifficulty.mults(lever, difficulty)
	local cfg = BossDifficulty.config(lever)
	if not cfg then
		return 1, 1
	end
	local D = BossDifficulty.normalize(lever, difficulty)
	return 1 + D * (tonumber(cfg.hpPerLevel) or 0), 1 + D * (tonumber(cfg.dmgPerLevel) or 0)
end

function BossDifficulty.apply(monster, lever, difficulty)
	if not monster or (tonumber(difficulty) or 0) <= 0 then
		return
	end
	local hpMult, dmgMult = BossDifficulty.mults(lever, difficulty)
	if hpMult <= 1 and dmgMult <= 1 then
		return
	end
	monster:scaleCombat(hpMult, dmgMult)
	return
end

function BossDifficulty.mods(lever, difficulty)
	local hpMult, dmgMult = BossDifficulty.mults(lever, difficulty)
	local red = {
		string.format("Boss HP +%d%%", math.floor((hpMult - 1) * 100 + 0.5)),
		string.format("Boss damage +%d%%", math.floor((dmgMult - 1) * 100 + 0.5)),
	}
	return red, {}
end

local function bannerNames(opts)
	local names = {}
	for _, name in ipairs(opts.banners or {}) do
		if #names < 5 then
			names[#names + 1] = name
		end
	end
	if #names == 0 then
		for _, p in ipairs(opts.players or {}) do
			if #names < 5 then
				names[#names + 1] = p:getName()
			end
		end
	end
	while #names < 5 do
		names[#names + 1] = ""
	end
	return names
end

local function send(player, pending, selected)
	local lever = pending.lever
	local red, green = BossDifficulty.mods(lever, selected)
	-- numbers: lowest, spinnerGate (0 = editable), raceId, selected, groupHighest, personalHighest, badLuck
	local numbers = {
		0,
		0,
		BossDifficulty.raceId(lever),
		selected,
		pending.maxAllowed,
		BossDifficulty.personalMax(player, lever),
		0,
	}
	player:sendBossDifficultySelection(0, numbers, pending.banners, red, green)
end

--- Open the dialog for `player`.
--- opts: { lever, players, banners?, selected?, onStart(difficulty), onCancel? }
--- Returns false when the lever has no difficulty (caller starts directly).
function BossDifficulty.open(player, opts)
	if not player or not opts or not BossDifficulty.isEnabled(opts.lever) then
		return false
	end
	local lever = opts.lever
	local players = opts.players or { player }
	local pending = {
		lever = lever,
		maxAllowed = BossDifficulty.groupMax(players, lever),
		banners = bannerNames(opts),
		onStart = opts.onStart,
		onCancel = opts.onCancel,
	}
	pendingByPlayerId[player:getId()] = pending
	local selected = math.min(BossDifficulty.normalize(lever, opts.selected), pending.maxAllowed)
	send(player, pending, selected)
	return true
end

function BossDifficulty.isPending(player)
	return player ~= nil and pendingByPlayerId[player:getId()] ~= nil
end

function BossDifficulty.onStart(player, difficulty)
	local pending = pendingByPlayerId[player:getId()]
	if not pending then
		return
	end
	pendingByPlayerId[player:getId()] = nil
	local D = math.min(BossDifficulty.normalize(pending.lever, difficulty), pending.maxAllowed)
	if pending.onStart then
		pending.onStart(D)
	end
end

function BossDifficulty.onPreview(player, difficulty)
	local pending = pendingByPlayerId[player:getId()]
	if not pending then
		return
	end
	local D = math.min(BossDifficulty.normalize(pending.lever, difficulty), pending.maxAllowed)
	send(player, pending, D)
end

function BossDifficulty.onCancel(player)
	local pending = pendingByPlayerId[player:getId()]
	if not pending then
		return
	end
	pendingByPlayerId[player:getId()] = nil
	if pending.onCancel then
		pending.onCancel()
	end
end
