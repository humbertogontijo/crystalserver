////////////////////////////////////////////////////////////////////////
// Crystal Server - an opensource roleplaying game
////////////////////////////////////////////////////////////////////////

#include "game/instance_fence.hpp"

#include "creatures/creature.hpp"
#include "creatures/players/player.hpp"
#include "enums/account_group_type.hpp"
#include "game/game.hpp"
#include "game/instance_registry.hpp"
#include "game/subarea_registry.hpp"

#include <algorithm>

namespace {
	InstanceId areaKey(InstanceId instanceId) {
		return instanceId.withChannel(0);
	}
}

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

void InstanceFenceRegistry::setHub(int32_t centerX, int32_t centerY, int32_t radius, const std::vector<uint8_t> &floors, uint8_t centerZ) {
	hubCenterX = centerX;
	hubCenterY = centerY;
	hubCenterZ = centerZ;
	hubRadius = radius > 0 ? radius : DEFAULT_HUB_WALK_RADIUS;
	hubFence.floors = floors;
	hubFence.allFloors = floors.empty();
}

std::optional<Position> InstanceFenceRegistry::hubCenter() const {
	if (!hubCenterX || !hubCenterY) {
		return std::nullopt;
	}
	return Position(static_cast<uint16_t>(*hubCenterX), static_cast<uint16_t>(*hubCenterY), hubCenterZ);
}

void InstanceFenceRegistry::setAreaFence(InstanceKind kind, uint32_t subareaId, Fence fence) {
	if (!isAreaKind(kind)) {
		return;
	}
	areaById[InstanceId(kind, subareaId, 0)] = std::move(fence);
}

void InstanceFenceRegistry::setPrivateFence(InstanceId instanceId, Fence fence) {
	if (!instanceId.isConcrete()) {
		return;
	}
	if (!fence.floors.empty()) {
		floorsByInstanceId[instanceId] = fence.floors;
	}
	privateById[instanceId] = std::move(fence);
}

void InstanceFenceRegistry::clearPrivateFence(InstanceId instanceId) {
	privateById.erase(instanceId);
	floorsByInstanceId.erase(instanceId);
}

bool InstanceFenceRegistry::hasPrivateFence(InstanceId instanceId) const {
	return privateById.contains(instanceId);
}

std::vector<uint8_t> InstanceFenceRegistry::floorsFor(InstanceId instanceId) const {
	if (const auto it = floorsByInstanceId.find(instanceId); it != floorsByInstanceId.end()) {
		return it->second;
	}
	if (const Fence* fence = fenceFor(instanceId); fence && !fence->allFloors) {
		return fence->floors;
	}
	return {};
}

void InstanceFenceRegistry::setFloors(InstanceId instanceId, const std::vector<uint8_t> &floors, bool allFloors) {
	if (instanceId.kind() == InstanceKind::Hub) {
		hubFence.floors = floors;
		hubFence.allFloors = allFloors || floors.empty();
		return;
	}
	if (isAreaKind(instanceId.kind())) {
		auto it = areaById.find(areaKey(instanceId));
		if (it != areaById.end()) {
			it->second.floors = floors;
			it->second.allFloors = allFloors || floors.empty();
		}
		return;
	}
	if (allFloors || floors.empty()) {
		floorsByInstanceId.erase(instanceId);
	} else {
		floorsByInstanceId[instanceId] = floors;
	}
	auto it = privateById.find(instanceId);
	if (it != privateById.end()) {
		it->second.floors = floors;
		it->second.allFloors = allFloors || floors.empty();
	}
}

const InstanceFenceRegistry::Fence* InstanceFenceRegistry::fenceFor(InstanceId instanceId) const {
	if (instanceId.kind() == InstanceKind::Hub) {
		return &hubFence;
	}
	if (const auto it = privateById.find(instanceId); it != privateById.end()) {
		return &it->second;
	}
	if (isAreaKind(instanceId.kind())) {
		const auto it = areaById.find(areaKey(instanceId));
		return it != areaById.end() ? &it->second : nullptr;
	}
	return nullptr;
}

bool InstanceFenceRegistry::hubContainsXY(int32_t x, int32_t y) const {
	if (!hubCenterX || !hubCenterY) {
		return false;
	}
	return std::abs(x - *hubCenterX) <= hubRadius && std::abs(y - *hubCenterY) <= hubRadius;
}

std::optional<InstanceFenceRegistry::Aabb> InstanceFenceRegistry::boundsFor(InstanceId instanceId) const {
	if (instanceId.kind() == InstanceKind::Hub) {
		if (!hubCenterX || !hubCenterY) {
			return std::nullopt;
		}
		const int32_t side = hubRadius * 2 + 1;
		return Aabb { *hubCenterX - hubRadius, *hubCenterY - hubRadius, side, side };
	}
	const Fence* fence = fenceFor(instanceId);
	if (!fence) {
		return std::nullopt;
	}
	if (fence->occupancy) {
		const auto &occ = *fence->occupancy;
		return Aabb { occ.originX, occ.originY, occ.width, occ.height };
	}
	return fence->aabb;
}

bool InstanceFenceRegistry::canWalk(const std::shared_ptr<Creature> &creature, const Position &toPos) const {
	if (!creature) {
		return true;
	}

	const InstanceId instanceId = creature->getInstanceId();
	if (instanceId.isWorld()) {
		return false;
	}

	const InstanceKind kind = instanceId.kind();
	const bool privateFence = privateById.contains(instanceId);

	// Open-world subarea layers: players and summons cross freely (players switch layer on
	// arrival); monsters stay on tiles of their own region or a connector it owns.
	if (isOpenWorldKind(kind) && !privateFence && g_subareas().enabled() && !g_instanceRegistry().isReserved(instanceId)) {
		if (creature->getPlayer() || creature->getMaster()) {
			return true;
		}
		return g_subareas().allows(g_subareas().regionAt(toPos), instanceId);
	}

	const bool areaRange = isAreaKind(kind) && !privateFence;
	const Fence* fence = fenceFor(instanceId);

	// Floor gate: cities/settlements allow every z; others use remembered floors when set.
	if (!areaRange) {
		const auto floorsIt = floorsByInstanceId.find(instanceId);
		if (floorsIt != floorsByInstanceId.end() && !floorsIt->second.empty()) {
			if (std::ranges::find(floorsIt->second, toPos.z) == floorsIt->second.end()) {
				return false;
			}
		} else if (fence && !fence->allowsFloor(toPos.z)) {
			return false;
		}
	}

	if (kind == InstanceKind::Hub) {
		return !hubCenterX || !hubCenterY || hubContainsXY(toPos.x, toPos.y);
	}
	if (fence) {
		return fence->containsXY(toPos.x, toPos.y);
	}

	// No fence registered: only players on private instances are held (gods excepted).
	const auto &player = creature->getPlayer();
	if (!player || !g_instanceRegistry().isPrivate(instanceId)) {
		return true;
	}
	const auto &group = player->getGroup();
	return group && group->id >= GROUP_TYPE_GOD;
}

InstanceId InstanceFenceRegistry::instanceForPosition(const Position &pos) const {
	if (hubContainsXY(pos.x, pos.y) && hubFence.allowsFloor(pos.z)) {
		return HUB_ADVENTURERS;
	}

	if (g_subareas().enabled()) {
		if (const uint32_t region = g_subareas().regionAt(pos); region != 0) {
			return g_subareas().mainInstanceFor(region);
		}
	}

	std::optional<InstanceId> area;
	for (const auto &[id, fence] : areaById) {
		if ((!fence.occupancy && !fence.aabb) || !fence.containsXY(pos.x, pos.y)) {
			continue;
		}
		if (!area || id.subareaId() < area->subareaId()) {
			area = id;
		}
	}
	return area.value_or(InstanceId::World);
}

bool InstanceFenceRegistry::containsPos(InstanceId instanceId, const Position &pos) const {
	if (instanceId.kind() == InstanceKind::Hub) {
		return hubFence.allowsFloor(pos.z) && hubContainsXY(pos.x, pos.y);
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
