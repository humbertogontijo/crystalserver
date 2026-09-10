////////////////////////////////////////////////////////////////////////
// Crystal Server - an opensource roleplaying game
////////////////////////////////////////////////////////////////////////

#pragma once

#include "game/movement/position.hpp"

#include <parallel_hashmap/phmap.h>

#include <cstdint>
#include <memory>
#include <optional>
#include <vector>

class Creature;

/**
 * Native instance walk fences (city/settlement/hub/private).
 * Lua registers masks/AABBs at load and instance build; serial + A* walks use C++.
 */
class InstanceFenceRegistry {
public:
	static constexpr uint32_t CITY_BASE = 1000000;
	static constexpr uint32_t HUB_ADVENTURERS = 2000000;
	static constexpr uint32_t PRIVATE_BASE = 3000000;
	static constexpr int32_t DEFAULT_HUB_WALK_RADIUS = 40;

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
	void setHub(int32_t centerX, int32_t centerY, int32_t radius, const std::vector<uint8_t> &floors);
	void setAreaFence(uint32_t areaId, Fence fence);
	void setPrivateFence(uint32_t instanceId, Fence fence);
	void clearPrivateFence(uint32_t instanceId);
	void setFloors(uint32_t instanceId, const std::vector<uint8_t> &floors, bool allFloors);

	[[nodiscard]] bool canWalk(const std::shared_ptr<Creature> &creature, const Position &toPos) const;

private:
	[[nodiscard]] const Fence *fenceFor(uint32_t instanceId) const;

	std::optional<int32_t> hubCenterX;
	std::optional<int32_t> hubCenterY;
	int32_t hubRadius = DEFAULT_HUB_WALK_RADIUS;
	Fence hubFence;
	phmap::flat_hash_map<uint32_t, Fence> areaById;
	phmap::flat_hash_map<uint32_t, Fence> privateById;
	phmap::flat_hash_map<uint32_t, std::vector<uint8_t>> floorsByInstanceId;
};

constexpr auto g_instanceFences = InstanceFenceRegistry::getInstance;
