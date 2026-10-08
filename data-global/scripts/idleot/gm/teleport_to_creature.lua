-- Replaces stock /goto: the caster also joins the target's instance (shared coordinates).
local teleportToCreature = TalkAction("/goto")

function teleportToCreature.onSay(player, words, param)
	logCommand(player, words, param)

	if param == "" then
		player:sendCancelMessage("Command param required.")
		return true
	end

	local target = Creature(param)
	if not target then
		player:sendCancelMessage("Creature not found.")
		return true
	end

	if not InstanceWorld.enterInstance(player, Instance.of(target), target:getPosition()) then
		player:sendCancelMessage("You can not teleport to " .. target:getName() .. ".")
		return true
	end
	ExpeditionProtocol.sendGodFlags(player)
	return true
end

teleportToCreature:separator(" ")
teleportToCreature:groupType("gamemaster")
teleportToCreature:register()
