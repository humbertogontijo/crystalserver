////////////////////////////////////////////////////////////////////////
// Crystal Server - an opensource roleplaying game
////////////////////////////////////////////////////////////////////////

#pragma once

#include "game/instance_id.hpp"
#include "game/movement/position.hpp"

#include <parallel_hashmap/phmap.h>

#include <cstdint>
#include <memory>
#include <optional>
#include <vector>

class Creature;

/**
 * Native instance walk fences.
 * - Area fences (city/settlement) are keyed by {kind, subareaId} and apply to every channel.
 *   They are the fallback while `openWorldSubareaInstances` is off or the region index is
 *   missing; with regions on they only resolve birth tiles no region covers.
 * - Private fences (hunt/raid/lobby/... reserved channels) are keyed by the full instance id.
 * - Open-world subarea kinds resolve through SubareaRegistry (tile -> region).
 * Lua registers masks/AABBs at load and instance build; serial + A* walks use C++.
 */
class InstanceFenceRegistry {
public:
	static constexpr int32_t DEFAULT_HUB_WALK_RADIUS = 40;
	/** The Adventurers' hub (one per world; channels split it like any other instance). */
	static constexpr InstanceId HUB_ADVENTURERS { InstanceKind::Hub, 1, 0 };

	struct Occupancy {
		int32_t originX = 0;
		int32_t originY = 0;
		int32_t width = 0;
		int32_t height = 0;
		std::vector<uint8_t> bits;

		[[nodiscard]] bool contains(int32_t worldX, int32_t worldY) const;
	};

	struct Aabb {
		int32_t x = 0;
		int32_t y = 0;
		int32_t w = 0;
		int32_t h = 0;

		[[nodiscard]] bool contains(int32_t worldX, int32_t worldY) const {
			return worldX >= x && worldX < x + w && worldY >= y && worldY < y + h;
		}
	};

	struct Fence {
		std::optional<Occupancy> occupancy;
		std::optional<Aabb> aabb;
		// Empty floors => all floors allowed (cities / settlements).
		std::vector<uint8_t> floors;
		bool allFloors = true;

		[[nodiscard]] bool allowsFloor(uint8_t z) const;
		[[nodiscard]] bool containsXY(int32_t x, int32_t y) const;
	};

	static InstanceFenceRegistry &getInstance();

	void clear();
	void setHub(int32_t centerX, int32_t centerY, int32_t radius, const std::vector<uint8_t> &floors, uint8_t centerZ = 7);
	/** Hub center tile; nullopt until InstanceWorld registers the hub. */
	[[nodiscard]] std::optional<Position> hubCenter() const;
	/** City / settlement geometry for every channel of `{kind, subareaId}`. */
	void setAreaFence(InstanceKind kind, uint32_t subareaId, Fence fence);
	void setPrivateFence(InstanceId instanceId, Fence fence);
	void clearPrivateFence(InstanceId instanceId);
	void setFloors(InstanceId instanceId, const std::vector<uint8_t> &floors, bool allFloors);

	[[nodiscard]] bool canWalk(const std::shared_ptr<Creature> &creature, const Position &toPos) const;
	/** Channel-0 instance a creature/item born at `pos` belongs to (hub, subarea region,
	 *  city/settlement area fence), else World. Private reserved channels are never inferred. */
	[[nodiscard]] InstanceId instanceForPosition(const Position &pos) const;
	/** True when `pos` lies inside the registered fence geometry and floors of `instanceId`. */
	[[nodiscard]] bool containsPos(InstanceId instanceId, const Position &pos) const;
	/** XY bounding box of the registered fence geometry (any floor); nullopt when none. */
	[[nodiscard]] std::optional<Aabb> boundsFor(InstanceId instanceId) const;
	[[nodiscard]] bool hasPrivateFence(InstanceId instanceId) const;
	/** Walkable floors registered for `instanceId`; empty = every floor. */
	[[nodiscard]] std::vector<uint8_t> floorsFor(InstanceId instanceId) const;

private:
	[[nodiscard]] const Fence* fenceFor(InstanceId instanceId) const;
	[[nodiscard]] bool hubContainsXY(int32_t x, int32_t y) const;

	std::optional<int32_t> hubCenterX;
	std::optional<int32_t> hubCenterY;
	uint8_t hubCenterZ = 7;
	int32_t hubRadius = DEFAULT_HUB_WALK_RADIUS;
	Fence hubFence;
	// Keyed by {kind, subareaId, channel 0}.
	phmap::flat_hash_map<InstanceId, Fence> areaById;
	phmap::flat_hash_map<InstanceId, Fence> privateById;
	phmap::flat_hash_map<InstanceId, std::vector<uint8_t>> floorsByInstanceId;
};

constexpr auto g_instanceFences = InstanceFenceRegistry::getInstance;
