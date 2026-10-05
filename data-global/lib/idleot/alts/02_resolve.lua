Alts = Alts or {}

--- Online player by GUID. Player(guid) is unreliable on some builds; scan live players.
function Alts.findOnlinePlayerByGuid(guid)
	guid = tonumber(guid) or 0
	if guid <= 0 then
		return nil
	end
	local direct = Player(guid)
	if direct and direct.getGuid and direct:getGuid() == guid then
		return direct
	end
	for _, online in ipairs(Game.getPlayers()) do
		if online:getGuid() == guid then
			return online
		end
	end
	return nil
end

function Alts.resolvePlayerByGuid(guid)
	guid = tonumber(guid) or 0
	if guid <= 0 then
		return nil
	end
	return Alts.findOnlinePlayerByGuid(guid) or (Game.getOfflinePlayer and Game.getOfflinePlayer(guid))
end

function Alts.resolveCharacter(nameOrGuid)
	if not nameOrGuid then
		return nil, "Invalid request."
	end
	local candidate
	if type(nameOrGuid) == "number" then
		candidate = Player(nameOrGuid) or Game.getOfflinePlayer(nameOrGuid)
	else
		local name = tostring(nameOrGuid)
		candidate = Player(name) or Game.getOfflinePlayer(name)
	end
	if not candidate then
		return nil, "Character not found."
	end
	return candidate
end

--- Same-account character (online or offline) by name or guid.
function Alts.resolveAccountMember(controller, nameOrGuid)
	if not controller then
		return nil, "Invalid request."
	end
	local accountId = controller:getAccountId()
	if not accountId or accountId == 0 then
		return nil, "No account."
	end
	local candidate, err = Alts.resolveCharacter(nameOrGuid)
	if not candidate then
		return nil, err
	end
	if candidate:getAccountId() ~= accountId then
		return nil, "Character is not on your account."
	end
	return candidate
end

--- Require controller and target share the same account (and account is non-zero).
function Alts.requireSameAccount(controller, target)
	if not controller or not target then
		return false, "Invalid request."
	end
	local ca = controller:getAccountId()
	local ta = target:getAccountId()
	if not ca or ca == 0 or not ta or ta == 0 then
		return false, "No account."
	end
	if ca ~= ta then
		return false, "Characters must be on your account."
	end
	return true
end

function Alts.sameAccount(a, b)
	return a and b and a:getAccountId() == b:getAccountId() and a:getAccountId() > 0
end

--- Outfit table for portraits (online or offline Player).
function Alts.outfitFrom(src)
	if not src or not src.getOutfit then
		return nil
	end
	local ok, look = pcall(function()
		return src:getOutfit()
	end)
	if not ok or type(look) ~= "table" then
		return nil
	end
	local lookType = tonumber(look.lookType or look.type) or 0
	if lookType <= 0 then
		return nil
	end
	return {
		type = lookType,
		head = tonumber(look.lookHead or look.head) or 0,
		body = tonumber(look.lookBody or look.body) or 0,
		legs = tonumber(look.lookLegs or look.legs) or 0,
		feet = tonumber(look.lookFeet or look.feet) or 0,
		addons = tonumber(look.lookAddons or look.addons) or 0,
	}
end

function Alts.vocationName(src)
	local vocation = src and src.getVocation and src:getVocation() or nil
	if not vocation then
		return ""
	end
	local ok, name = pcall(function()
		return vocation:getName()
	end)
	return ok and type(name) == "string" and name or ""
end

--- Level + vocation + outfit for slots / automation catalogs.
function Alts.memberProfile(src)
	if not src then
		return { level = 0, vocation = "", outfit = nil }
	end
	return {
		level = src.getLevel and src:getLevel() or 0,
		vocation = Alts.vocationName(src),
		outfit = Alts.outfitFrom(src),
	}
end
