////////////////////////////////////////////////////////////////////////
// Crystal Server - an opensource roleplaying game
////////////////////////////////////////////////////////////////////////

#pragma once

#include "game/instance_id.hpp"

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
	uint32_t create(InstanceId instanceId);
	/** Stops respawn and removes every monster the instance spawns produced. */
	void clear(InstanceId instanceId);
	[[nodiscard]] bool has(InstanceId instanceId) const;

	/**
	 * Open-world subarea layer (public channel of a city/settlement/hunt/wild/connector region):
	 * on first use clones the world blocks standing on the key's region and on every connector
	 * it owns (connector blocks are cloned once per owner). No-op for other keys or when
	 * subarea instances are off. Returns the started block count (0 when already live).
	 */
	uint32_t ensureOpenWorld(InstanceId instanceId);
	/** Starts spawns of occupied open-world layers (players bound by script skip ensureOpenWorld). */
	void ensureOccupiedOpenWorld();
	/** Drops the subarea -> world spawn index; call when the world spawn list is reloaded. */
	void invalidateWorldSpawnIndex();

private:
	void indexWorldSpawns();

	phmap::flat_hash_map<InstanceId, std::vector<std::shared_ptr<SpawnMonster>>> spawnsByInstance;
	// Owning subarea id -> world spawn templates with at least one block on it (or on a connector it owns).
	phmap::flat_hash_map<uint32_t, std::vector<std::shared_ptr<SpawnMonster>>> worldSpawnsBySubarea;
	bool worldSpawnsIndexed = false;
};

constexpr auto g_instanceSpawns = InstanceSpawns::getInstance;
