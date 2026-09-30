////////////////////////////////////////////////////////////////////////
// Crystal Server - an opensource roleplaying game
////////////////////////////////////////////////////////////////////////

#pragma once

#include <parallel_hashmap/phmap.h>

#include <cstdint>
#include <memory>
#include <vector>

class SpawnMonster;

/**
 * Per-instance copies of the world monster spawn XML.
 * create() clones every non-boss spawn block whose tile lies inside the instance
 * fence into SpawnMonster objects bound to that instance and starts them; monsters
 * respawn natively with the XML interval. The private fence must be registered first.
 */
class InstanceSpawns {
public:
	static InstanceSpawns &getInstance();

	/** Replaces any spawns already bound to `instanceId`. Returns the number of spawn blocks. */
	uint32_t create(uint32_t instanceId);
	/** Stops respawn and removes every monster the instance spawns produced. */
	void clear(uint32_t instanceId);
	[[nodiscard]] bool has(uint32_t instanceId) const;

private:
	phmap::flat_hash_map<uint32_t, std::vector<std::shared_ptr<SpawnMonster>>> spawnsByInstance;
};

constexpr auto g_instanceSpawns = InstanceSpawns::getInstance;
