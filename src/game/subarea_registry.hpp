////////////////////////////////////////////////////////////////////////
// Crystal Server - an opensource roleplaying game
////////////////////////////////////////////////////////////////////////

#pragma once

#include "game/instance_id.hpp"
#include "game/movement/position.hpp"
#include "io/region_index.hpp"

#include <parallel_hashmap/phmap.h>

#include <cstdint>
#include <string>
#include <vector>

/**
 * Tile -> open-world subarea region (`lib/idleot/subareas/regions.generated.bin`,
 * written by the asset-pipeline subarea partition). A region is multi-floor; its
 * instance key is {kindOf(region), region, channel}. Connector regions join two or
 * more regions and belong to each of them: a connector tile accepts any owner's key.
 * Region 0 = unknown tile (callers keep the current key).
 */
class SubareaRegistry {
public:
	static SubareaRegistry &getInstance();

	bool load(const std::string &path);
	[[nodiscard]] bool loaded() const {
		return !index.empty();
	}
	/** Loaded and `openWorldSubareaInstances` is on. */
	[[nodiscard]] bool enabled() const;

	[[nodiscard]] uint32_t regionAt(const Position &pos) const {
		return index.at(pos.x, pos.y, pos.z);
	}
	[[nodiscard]] const RegionRecord* region(uint32_t id) const {
		return index.region(id);
	}
	[[nodiscard]] InstanceKind kindOf(uint32_t id) const;
	[[nodiscard]] bool isConnector(uint32_t id) const {
		return kindOf(id) == InstanceKind::Connector;
	}

	/** True when a creature keyed `instanceId` belongs on region `regionId`: the key's own
	 *  subarea, or a connector listing it as an owner. */
	[[nodiscard]] bool allows(uint32_t regionId, InstanceId instanceId) const;
	/** Main-channel key that owns region `regionId` (connectors: lowest owner); World for 0. */
	[[nodiscard]] InstanceId mainInstanceFor(uint32_t regionId) const;
	/** Main-channel keys whose creatures may spawn on region `regionId` (every owner for connectors). */
	[[nodiscard]] const std::vector<InstanceId> &ownerInstancesFor(uint32_t regionId) const;

private:
	/** Per-region keys resolved at load (allows/mainInstanceFor run on every creature step). */
	struct Resolved {
		InstanceKind kind = InstanceKind::Wild;
		/** Main-channel key; connectors: the lowest owner (World when ownerless). */
		InstanceId main;
		/** Main-channel keys of the owners; the region itself when not a connector. */
		std::vector<InstanceId> owners;
	};

	[[nodiscard]] const Resolved* resolve(uint32_t id) const;

	RegionIndex index;
	phmap::flat_hash_map<uint32_t, Resolved> resolved;
};

constexpr auto g_subareas = SubareaRegistry::getInstance;
