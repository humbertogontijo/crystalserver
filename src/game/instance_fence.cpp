////////////////////////////////////////////////////////////////////////
// Crystal Server - an opensource roleplaying game
////////////////////////////////////////////////////////////////////////

#include "game/instance_fence.hpp"

#include "creatures/creature.hpp"
#include "creatures/players/player.hpp"
#include "enums/account_group_type.hpp"
#include "game/game.hpp"

#include <algorithm>

bool InstanceFenceRegistry::Occupancy::contains(int32_t worldX, int32_t worldY) const {
	if (width <= 0 || height <= 0 || bits.empty()) {
		return false;
	}
	const int32_t lx = worldX - originX;
	const int32_t ly = worldY - originY;
	if (lx < 0 || ly < 0 || lx >= width || ly >= height) {
		return false;
	}
	const size_t index = static_cast<size_t>(ly) * static_cast<size_t>(width) + static_cast<size_t>(lx);
	const size_t byteIndex = index / 8;
	if (byteIndex >= bits.size()) {
		return false;
	}
	return (bits[byteIndex] & (1u << (index & 7))) != 0;
}

bool InstanceFenceRegistry::Fence::allowsFloor(uint8_t z) const {
	if (allFloors || floors.empty()) {
		return true;
	}
	return std::find(floors.begin(), floors.end(), z) != floors.end();
}

bool InstanceFenceRegistry::Fence::containsXY(int32_t x, int32_t y) const {
	if (occupancy) {
		return occupancy->contains(x, y);
	}
	if (aabb) {
		return aabb->contains(x, y);
	}
	// No geometry registered → allow (matches Lua fall-through).
	return true;
}

InstanceFenceRegistry &InstanceFenceRegistry::getInstance() {
	static InstanceFenceRegistry instance;
	return instance;
}

void InstanceFenceRegistry::clear() {
	hubCenterX.reset();
	hubCenterY.reset();
	hubRadius = DEFAULT_HUB_WALK_RADIUS;
	hubFence = Fence {};
	areaById.clear();
	privateById.clear();
	floorsByInstanceId.clear();
}

void InstanceFenceRegistry::setHub(int32_t centerX, int32_t centerY, int32_t radius, const std::vector<uint8_t> &floors) {
	hubCenterX = centerX;
	hubCenterY = centerY;
	hubRadius = radius > 0 ? radius : DEFAULT_HUB_WALK_RADIUS;
	hubFence.floors = floors;
	hubFence.allFloors = floors.empty();
	floorsByInstanceId[HUB_ADVENTURERS] = floors;
}

void InstanceFenceRegistry::setAreaFence(uint32_t areaId, Fence fence) {
	areaById[areaId] = std::move(fence);
}

void InstanceFenceRegistry::setPrivateFence(uint32_t instanceId, Fence fence) {
	if (instanceId < PRIVATE_BASE) {
		return;
	}
	if (!fence.floors.empty()) {
		floorsByInstanceId[instanceId] = fence.floors;
	}
	privateById[instanceId] = std::move(fence);
}

void InstanceFenceRegistry::clearPrivateFence(uint32_t instanceId) {
	privateById.erase(instanceId);
	floorsByInstanceId.erase(instanceId);
}

void InstanceFenceRegistry::setFloors(uint32_t instanceId, const std::vector<uint8_t> &floors, bool allFloors) {
	if (allFloors || floors.empty()) {
		floorsByInstanceId.erase(instanceId);
	} else {
		floorsByInstanceId[instanceId] = floors;
	}
	if (instanceId == HUB_ADVENTURERS) {
		hubFence.floors = floors;
		hubFence.allFloors = allFloors || floors.empty();
		return;
	}
	if (instanceId >= CITY_BASE && instanceId < HUB_ADVENTURERS) {
		auto it = areaById.find(instanceId - CITY_BASE);
		if (it != areaById.end()) {
			it->second.floors = floors;
			it->second.allFloors = allFloors || floors.empty();
		}
		return;
	}
	auto it = privateById.find(instanceId);
	if (it != privateById.end()) {
		it->second.floors = floors;
		it->second.allFloors = allFloors || floors.empty();
	}
}

const InstanceFenceRegistry::Fence *InstanceFenceRegistry::fenceFor(uint32_t instanceId) const {
	if (instanceId == HUB_ADVENTURERS) {
		return &hubFence;
	}
	if (instanceId >= CITY_BASE && instanceId < HUB_ADVENTURERS) {
		const auto it = areaById.find(instanceId - CITY_BASE);
		return it != areaById.end() ? &it->second : nullptr;
	}
	const auto it = privateById.find(instanceId);
	return it != privateById.end() ? &it->second : nullptr;
}

bool InstanceFenceRegistry::canWalk(const std::shared_ptr<Creature> &creature, const Position &toPos) const {
	if (!creature) {
		return true;
	}

	const uint32_t instanceId = creature->getInstanceId();
	if (instanceId == 0) {
		return false;
	}

	const bool cityRange = instanceId >= CITY_BASE && instanceId < HUB_ADVENTURERS;

	// Floor gate: cities/settlements allow every z; others use remembered floors when set.
	if (!cityRange) {
		const auto floorsIt = floorsByInstanceId.find(instanceId);
		if (floorsIt != floorsByInstanceId.end() && !floorsIt->second.empty()) {
			const uint8_t z = toPos.z;
			if (std::find(floorsIt->second.begin(), floorsIt->second.end(), z) == floorsIt->second.end()) {
				return false;
			}
		} else if (const Fence *fence = fenceFor(instanceId)) {
			if (!fence->allowsFloor(toPos.z)) {
				return false;
			}
		}
	}

	if (instanceId == HUB_ADVENTURERS) {
		if (!hubCenterX || !hubCenterY) {
			return true;
		}
		const int32_t dx = std::abs(static_cast<int32_t>(toPos.x) - *hubCenterX);
		const int32_t dy = std::abs(static_cast<int32_t>(toPos.y) - *hubCenterY);
		return dx <= hubRadius && dy <= hubRadius;
	}

	if (cityRange) {
		const Fence *fence = fenceFor(instanceId);
		if (!fence) {
			return true;
		}
		return fence->containsXY(toPos.x, toPos.y);
	}

	if (const Fence *fence = fenceFor(instanceId)) {
		return fence->containsXY(toPos.x, toPos.y);
	}

	// No private fence registered: monsters may path; players on private ids are fenced.
	if (creature->getMonster()) {
		return true;
	}

	if (const auto &player = creature->getPlayer()) {
		if (instanceId >= PRIVATE_BASE) {
			const auto &group = player->getGroup();
			if (group && group->id >= GROUP_TYPE_GOD) {
				return true;
			}
			return false;
		}
	}

	return true;
}

uint32_t InstanceFenceRegistry::instanceForPosition(const Position &pos) const {
	if (hubCenterX && hubCenterY) {
		const int32_t dx = std::abs(static_cast<int32_t>(pos.x) - *hubCenterX);
		const int32_t dy = std::abs(static_cast<int32_t>(pos.y) - *hubCenterY);
		if (dx <= hubRadius && dy <= hubRadius) {
			return HUB_ADVENTURERS;
		}
	}

	std::optional<uint32_t> areaId;
	for (const auto &[id, fence] : areaById) {
		if ((!fence.occupancy && !fence.aabb) || !fence.containsXY(pos.x, pos.y)) {
			continue;
		}
		if (!areaId || id < *areaId) {
			areaId = id;
		}
	}
	return areaId ? CITY_BASE + *areaId : 0;
}

bool InstanceFenceRegistry::containsPos(uint32_t instanceId, const Position &pos) const {
	if (instanceId == HUB_ADVENTURERS) {
		if (!hubCenterX || !hubCenterY || !hubFence.allowsFloor(pos.z)) {
			return false;
		}
		const int32_t dx = std::abs(static_cast<int32_t>(pos.x) - *hubCenterX);
		const int32_t dy = std::abs(static_cast<int32_t>(pos.y) - *hubCenterY);
		return dx <= hubRadius && dy <= hubRadius;
	}

	const Fence* fence = fenceFor(instanceId);
	if (!fence || (!fence->occupancy && !fence->aabb)) {
		return false;
	}
	if (const auto floorsIt = floorsByInstanceId.find(instanceId); floorsIt != floorsByInstanceId.end() && !floorsIt->second.empty()) {
		if (std::find(floorsIt->second.begin(), floorsIt->second.end(), pos.z) == floorsIt->second.end()) {
			return false;
		}
	} else if (!fence->allowsFloor(pos.z)) {
		return false;
	}
	return fence->containsXY(pos.x, pos.y);
}
