////////////////////////////////////////////////////////////////////////
// Crystal Server - an opensource roleplaying game
////////////////////////////////////////////////////////////////////////

#include "game/instance_spawns.hpp"

#include "creatures/monsters/spawns/spawn_monster.hpp"
#include "creatures/players/player.hpp"
#include "game/game.hpp"
#include "game/instance_registry.hpp"
#include "game/instance_fence.hpp"
#include "game/subarea_registry.hpp"

InstanceSpawns &InstanceSpawns::getInstance() {
	static InstanceSpawns instance;
	return instance;
}

uint32_t InstanceSpawns::create(InstanceId instanceId) {
	clear(instanceId);

	const auto &fences = g_instanceFences();
	const auto bounds = fences.boundsFor(instanceId);
	if (!bounds) {
		g_logger().warn("[InstanceSpawns::create] instance {} has no registered fence", instanceId);
		return 0;
	}
	const auto inFence = [&fences, &bounds, instanceId](const spawnBlock_t &sb) {
		return bounds->contains(sb.pos.x, sb.pos.y) && !sb.hasBoss() && fences.containsPos(instanceId, sb.pos);
	};

	std::vector<std::shared_ptr<SpawnMonster>> spawns;
	uint32_t blocks = 0;
	for (const auto &worldSpawn : g_game().map.spawnsMonster.getspawnMonsterList()) {
		if (!worldSpawn || !worldSpawn->anyBlock(inFence)) {
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

void InstanceSpawns::indexWorldSpawns() {
	worldSpawnsIndexed = true;
	worldSpawnsBySubarea.clear();
	const auto &subareas = g_subareas();
	const auto indexList = [&](SpawnsMonster &spawns) {
		for (const auto &worldSpawn : spawns.getspawnMonsterList()) {
			if (!worldSpawn) {
				continue;
			}
			phmap::flat_hash_set<uint32_t> owners;
			(void)worldSpawn->anyBlock([&](const spawnBlock_t &sb) {
				for (const auto &owner : subareas.ownerInstancesFor(subareas.regionAt(sb.pos))) {
					owners.insert(owner.subareaId());
				}
				return false;
			});
			for (const auto owner : owners) {
				worldSpawnsBySubarea[owner].push_back(worldSpawn);
			}
		}
	};
	indexList(g_game().map.spawnsMonster);
	for (auto &custom : g_game().map.spawnsMonsterCustomMaps) {
		indexList(custom);
	}
}

uint32_t InstanceSpawns::ensureOpenWorld(InstanceId instanceId) {
	const auto &subareas = g_subareas();
	if (!subareas.enabled() || !isOpenWorldKind(instanceId.kind())
	    || g_instanceRegistry().isPrivate(instanceId) || spawnsByInstance.contains(instanceId)) {
		return 0;
	}
	if (!worldSpawnsIndexed) {
		indexWorldSpawns();
	}

	const auto onLayer = [&subareas, instanceId](const spawnBlock_t &sb) {
		const uint32_t region = subareas.regionAt(sb.pos);
		return region != 0 && !sb.hasBoss() && subareas.allows(region, instanceId);
	};

	std::vector<std::shared_ptr<SpawnMonster>> spawns;
	uint32_t blocks = 0;
	if (const auto it = worldSpawnsBySubarea.find(instanceId.subareaId()); it != worldSpawnsBySubarea.end()) {
		for (const auto &worldSpawn : it->second) {
			auto spawn = std::make_shared<SpawnMonster>(worldSpawn->getCenterPos(), worldSpawn->getRadius(), instanceId);
			const uint32_t copied = worldSpawn->cloneBlocksInto(*spawn, onLayer);
			if (copied == 0) {
				continue;
			}
			blocks += copied;
			spawns.emplace_back(std::move(spawn));
		}
	}

	// Registered even when empty so an occupied layer without blocks is not rescanned.
	auto &live = spawnsByInstance[instanceId];
	live = std::move(spawns);
	// The main channel stays up once created (respawns keep running like the stock world;
	// unwatched monsters idle). Other channels are registry records: its idle sweep releases them.
	g_instanceRegistry().open(instanceId);
	for (const auto &spawn : live) {
		spawn->startup();
	}
	g_logger().debug("[InstanceSpawns::ensureOpenWorld] layer {} started {} spawn blocks", instanceId, blocks);
	return blocks;
}

void InstanceSpawns::ensureOccupiedOpenWorld() {
	if (!g_subareas().enabled()) {
		return;
	}
	for (const auto &instanceId : g_instanceRegistry().occupiedInstances()) {
		ensureOpenWorld(instanceId);
	}
}

void InstanceSpawns::invalidateWorldSpawnIndex() {
	worldSpawnsIndexed = false;
	worldSpawnsBySubarea.clear();
}

void InstanceSpawns::clear(InstanceId instanceId) {
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

bool InstanceSpawns::has(InstanceId instanceId) const {
	return spawnsByInstance.contains(instanceId);
}
