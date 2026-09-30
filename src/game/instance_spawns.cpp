////////////////////////////////////////////////////////////////////////
// Crystal Server - an opensource roleplaying game
////////////////////////////////////////////////////////////////////////

#include "game/instance_spawns.hpp"

#include "creatures/monsters/spawns/spawn_monster.hpp"
#include "game/game.hpp"
#include "game/instance_fence.hpp"

InstanceSpawns &InstanceSpawns::getInstance() {
	static InstanceSpawns instance;
	return instance;
}

uint32_t InstanceSpawns::create(uint32_t instanceId) {
	clear(instanceId);

	const auto &fences = g_instanceFences();
	const auto inFence = [&fences, instanceId](const spawnBlock_t &sb) {
		return !sb.hasBoss() && fences.containsPos(instanceId, sb.pos);
	};

	std::vector<std::shared_ptr<SpawnMonster>> spawns;
	uint32_t blocks = 0;
	for (const auto &worldSpawn : g_game().map.spawnsMonster.getspawnMonsterList()) {
		if (!worldSpawn) {
			continue;
		}
		auto spawn = std::make_shared<SpawnMonster>(worldSpawn->getCenterPos(), worldSpawn->getRadius(), instanceId);
		const uint32_t copied = worldSpawn->cloneBlocksInto(*spawn, inFence);
		if (copied == 0) {
			continue;
		}
		blocks += copied;
		spawns.emplace_back(std::move(spawn));
	}

	if (spawns.empty()) {
		g_logger().warn("[InstanceSpawns::create] instance {} has no world spawn blocks inside its fence", instanceId);
		return 0;
	}

	for (const auto &spawn : spawns) {
		spawn->startup();
	}
	spawnsByInstance[instanceId] = std::move(spawns);
	g_logger().debug("[InstanceSpawns::create] instance {} started {} spawn blocks", instanceId, blocks);
	return blocks;
}

void InstanceSpawns::clear(uint32_t instanceId) {
	const auto it = spawnsByInstance.find(instanceId);
	if (it == spawnsByInstance.end()) {
		return;
	}
	const auto spawns = std::move(it->second);
	spawnsByInstance.erase(it);
	for (const auto &spawn : spawns) {
		spawn->stopEvent();
		spawn->removeSpawnedCreatures();
		spawn->removeMonsters();
	}
}

bool InstanceSpawns::has(uint32_t instanceId) const {
	return spawnsByInstance.contains(instanceId);
}
