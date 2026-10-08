////////////////////////////////////////////////////////////////////////
// Crystal Server - an opensource roleplaying game
////////////////////////////////////////////////////////////////////////

#include "game/instance_registry.hpp"

#include "creatures/players/player.hpp"
#include "enums/account_group_type.hpp"
#include "game/instance_fence.hpp"
#include "utils/tools.hpp"

namespace {
	constexpr uint32_t kChannelSpan = 0x10000;

	bool isGod(const std::shared_ptr<Player> &player) {
		if (!player) {
			return false;
		}
		const auto &group = player->getGroup();
		return group && group->id >= GROUP_TYPE_GOD;
	}

	bool isAllocatableKind(InstanceKind kind) {
		return kind != InstanceKind::World && kind != InstanceKind::Any && kind < InstanceKind::Count;
	}
}

InstanceRegistry &InstanceRegistry::getInstance() {
	static InstanceRegistry instance;
	return instance;
}

void InstanceRegistry::setKindCapacity(InstanceKind kind, uint32_t maxPlayers) {
	const auto index = static_cast<size_t>(kind);
	if (index < capacityByKind.size()) {
		capacityByKind[index] = maxPlayers;
	}
}

uint32_t InstanceRegistry::kindCapacity(InstanceKind kind) const {
	const auto index = static_cast<size_t>(kind);
	return index < capacityByKind.size() ? capacityByKind[index] : 0;
}

InstanceRegistry::Instance &InstanceRegistry::emplace(InstanceId id, bool reserved, std::string owner, std::string tag) {
	auto &channels = channelsByGroup[groupKey(id.kind(), id.subareaId())];
	Instance record;
	record.id = id;
	record.reserved = reserved;
	record.owner = std::move(owner);
	record.tag = std::move(tag);
	record.createdAt = OTSYS_TIME();
	return channels.insert_or_assign(id.channel(), std::move(record)).first->second;
}

std::optional<InstanceId> InstanceRegistry::allocate(InstanceKind kind, uint32_t subareaId, const AllocOptions &options) {
	if (!isAllocatableKind(kind)) {
		return std::nullopt;
	}
	const InstanceId group = groupKey(kind, subareaId);
	const uint32_t first = hasImplicitMainChannel(kind) ? 1 : 0;
	// Reserved sessions walk forward from the last number handed out; public overflow layers
	// take the lowest free number so players see small channel numbers.
	uint32_t start = first;
	if (options.reserved) {
		if (const auto it = nextReservedByGroup.find(group); it != nextReservedByGroup.end()) {
			start = it->second;
		}
	}

	const auto groupIt = channelsByGroup.find(group);
	for (uint32_t step = 0; step < kChannelSpan; ++step) {
		const uint32_t number = (start + step) % kChannelSpan;
		if (number < first) {
			continue;
		}
		const auto channel = static_cast<uint16_t>(number);
		if (groupIt != channelsByGroup.end() && groupIt->second.contains(channel)) {
			continue;
		}
		const InstanceId id(kind, subareaId, channel);
		// Never recycle a number that still has bodies on it (released without a sweep).
		if (playerCount(id) > 0) {
			continue;
		}
		if (options.reserved) {
			nextReservedByGroup[group] = number + 1;
		}
		emplace(id, options.reserved, options.owner, options.tag);
		return id;
	}
	g_logger().error("[InstanceRegistry::allocate] no free channel for {}:{}", instanceKindName(kind), subareaId);
	return std::nullopt;
}

void InstanceRegistry::open(InstanceId instanceId) {
	if (!instanceId.isConcrete() || instanceId.isImplicitMain()) {
		return;
	}
	auto &channels = channelsByGroup[groupKey(instanceId.kind(), instanceId.subareaId())];
	if (!channels.contains(instanceId.channel())) {
		emplace(instanceId, false, {}, {});
	}
}

bool InstanceRegistry::markClosing(InstanceId instanceId) {
	const auto it = channelsByGroup.find(groupKey(instanceId.kind(), instanceId.subareaId()));
	if (it == channelsByGroup.end()) {
		return false;
	}
	const auto channelIt = it->second.find(instanceId.channel());
	if (channelIt == it->second.end()) {
		return false;
	}
	channelIt->second.state = State::Closing;
	return true;
}

bool InstanceRegistry::release(InstanceId instanceId) {
	const auto it = channelsByGroup.find(groupKey(instanceId.kind(), instanceId.subareaId()));
	if (it == channelsByGroup.end()) {
		return false;
	}
	const bool erased = it->second.erase(instanceId.channel()) > 0;
	if (it->second.empty()) {
		channelsByGroup.erase(it);
	}
	return erased;
}

const InstanceRegistry::Instance* InstanceRegistry::find(InstanceId instanceId) const {
	const auto it = channelsByGroup.find(groupKey(instanceId.kind(), instanceId.subareaId()));
	if (it == channelsByGroup.end()) {
		return nullptr;
	}
	const auto channelIt = it->second.find(instanceId.channel());
	return channelIt != it->second.end() ? &channelIt->second : nullptr;
}

bool InstanceRegistry::isLive(InstanceId instanceId) const {
	if (instanceId.isWorld()) {
		return true;
	}
	if (instanceId.isAny()) {
		return false;
	}
	const auto* record = find(instanceId);
	if (record) {
		return record->state == State::Live;
	}
	return instanceId.isImplicitMain();
}

bool InstanceRegistry::isReserved(InstanceId instanceId) const {
	const auto* record = find(instanceId);
	return record && record->reserved;
}

bool InstanceRegistry::isPrivate(InstanceId instanceId) const {
	if (!instanceId.isConcrete()) {
		return false;
	}
	return isPrivateOnlyKind(instanceId.kind()) || isReserved(instanceId);
}

std::vector<InstanceId> InstanceRegistry::channelsOf(InstanceKind kind, uint32_t subareaId) const {
	std::vector<InstanceId> out;
	if (hasImplicitMainChannel(kind)) {
		out.emplace_back(kind, subareaId, 0);
	}
	if (const auto it = channelsByGroup.find(groupKey(kind, subareaId)); it != channelsByGroup.end()) {
		for (const auto &[number, record] : it->second) {
			if (number == 0 && hasImplicitMainChannel(kind)) {
				continue;
			}
			out.emplace_back(kind, subareaId, number);
		}
	}
	return out;
}

std::vector<InstanceId> InstanceRegistry::all() const {
	std::vector<InstanceId> out;
	for (const auto &[group, channels] : channelsByGroup) {
		for (const auto &[number, record] : channels) {
			out.push_back(record.id);
		}
	}
	std::sort(out.begin(), out.end());
	return out;
}

bool InstanceRegistry::setWorldType(InstanceId instanceId, WorldType_t type) {
	if (!isLive(instanceId) || instanceId.isWorld()) {
		return false;
	}
	auto &channels = channelsByGroup[groupKey(instanceId.kind(), instanceId.subareaId())];
	auto it = channels.find(instanceId.channel());
	if (it == channels.end()) {
		// Implicit main channels get a record only to hold the override.
		it = channels.emplace(instanceId.channel(), Instance { .id = instanceId, .createdAt = OTSYS_TIME() }).first;
	}
	it->second.worldType = type;
	return true;
}

std::optional<WorldType_t> InstanceRegistry::worldType(InstanceId instanceId) const {
	const auto* record = find(instanceId);
	return record ? record->worldType : std::nullopt;
}

void InstanceRegistry::CreatureIndex::bind(uint32_t creatureId, InstanceId instanceId) {
	if (creatureId == 0) {
		return;
	}
	const auto [it, inserted] = instanceById.try_emplace(creatureId, instanceId);
	if (!inserted) {
		if (it->second == instanceId) {
			return;
		}
		if (const auto oldIt = idsByInstance.find(it->second); oldIt != idsByInstance.end()) {
			oldIt->second.erase(creatureId);
			if (oldIt->second.empty()) {
				idsByInstance.erase(oldIt);
			}
		}
		it->second = instanceId;
	}
	idsByInstance[instanceId].insert(creatureId);
}

void InstanceRegistry::CreatureIndex::rebind(uint32_t creatureId, InstanceId instanceId) {
	if (instanceById.contains(creatureId)) {
		bind(creatureId, instanceId);
	}
}

void InstanceRegistry::CreatureIndex::unbind(uint32_t creatureId) {
	const auto it = instanceById.find(creatureId);
	if (it == instanceById.end()) {
		return;
	}
	if (const auto idsIt = idsByInstance.find(it->second); idsIt != idsByInstance.end()) {
		idsIt->second.erase(creatureId);
		if (idsIt->second.empty()) {
			idsByInstance.erase(idsIt);
		}
	}
	instanceById.erase(it);
}

uint32_t InstanceRegistry::CreatureIndex::count(InstanceId instanceId) const {
	const auto it = idsByInstance.find(instanceId);
	return it != idsByInstance.end() ? static_cast<uint32_t>(it->second.size()) : 0;
}

bool InstanceRegistry::CreatureIndex::contains(InstanceId instanceId, uint32_t creatureId) const {
	const auto it = idsByInstance.find(instanceId);
	return it != idsByInstance.end() && it->second.contains(creatureId);
}

std::vector<uint32_t> InstanceRegistry::CreatureIndex::ids(InstanceId instanceId) const {
	std::vector<uint32_t> out;
	if (const auto it = idsByInstance.find(instanceId); it != idsByInstance.end()) {
		out.assign(it->second.begin(), it->second.end());
	}
	return out;
}

void InstanceRegistry::setPlayerInstance(uint32_t playerId, InstanceId instanceId) {
	playerIndex.bind(playerId, instanceId);
}

void InstanceRegistry::updatePlayerInstance(uint32_t playerId, InstanceId instanceId) {
	playerIndex.rebind(playerId, instanceId);
}

void InstanceRegistry::removePlayer(uint32_t playerId) {
	playerIndex.unbind(playerId);
}

uint32_t InstanceRegistry::playerCount(InstanceId instanceId) const {
	return playerIndex.count(instanceId);
}

uint32_t InstanceRegistry::playerCountExcluding(InstanceId instanceId, uint32_t playerId) const {
	const auto count = playerIndex.count(instanceId);
	return playerId != 0 && playerIndex.contains(instanceId, playerId) ? count - 1 : count;
}

std::vector<uint32_t> InstanceRegistry::members(InstanceId instanceId) const {
	return playerIndex.ids(instanceId);
}

void InstanceRegistry::setMonsterInstance(uint32_t monsterId, InstanceId instanceId) {
	monsterIndex.bind(monsterId, instanceId);
}

void InstanceRegistry::updateMonsterInstance(uint32_t monsterId, InstanceId instanceId) {
	monsterIndex.rebind(monsterId, instanceId);
}

void InstanceRegistry::removeMonster(uint32_t monsterId) {
	monsterIndex.unbind(monsterId);
}

uint32_t InstanceRegistry::monsterCount(InstanceId instanceId) const {
	return monsterIndex.count(instanceId);
}

std::vector<uint32_t> InstanceRegistry::monsters(InstanceId instanceId) const {
	return monsterIndex.ids(instanceId);
}

std::optional<InstanceId> InstanceRegistry::pickChannel(InstanceKind kind, uint32_t subareaId, std::optional<uint16_t> preferred, const std::shared_ptr<Player> &player) {
	if (!isAllocatableKind(kind)) {
		return std::nullopt;
	}
	const uint32_t cap = kindCapacity(kind);
	const bool god = isGod(player);
	const uint32_t self = player ? player->getID() : 0;

	const auto room = [&](uint16_t channel) {
		if (god || cap == 0) {
			return true;
		}
		return playerCountExcluding(InstanceId(kind, subareaId, channel), self) < cap;
	};
	const auto isPublic = [&](uint16_t channel) {
		if (channel == 0 && hasImplicitMainChannel(kind)) {
			return true;
		}
		const auto* record = find(InstanceId(kind, subareaId, channel));
		return record && !record->reserved && record->state == State::Live;
	};

	// Same layer number as before (opened on demand) so groups crossing together stay together.
	if (preferred) {
		const InstanceId id(kind, subareaId, *preferred);
		const auto* record = find(id);
		const bool blocked = record && (record->reserved || record->state != State::Live);
		if (!blocked && room(*preferred)) {
			open(id);
			return id;
		}
	}

	for (const auto &id : channelsOf(kind, subareaId)) {
		if (isPublic(id.channel()) && room(id.channel())) {
			open(id);
			return id;
		}
	}

	return allocate(kind, subareaId, AllocOptions { .reserved = false });
}

std::vector<InstanceId> InstanceRegistry::sweepIdle(int64_t nowMs, int64_t graceMs) {
	std::vector<InstanceId> idle;
	for (auto &[group, channels] : channelsByGroup) {
		for (auto &[number, record] : channels) {
			if (record.reserved || record.state != State::Live || record.id.isImplicitMain()) {
				continue;
			}
			if (playerCount(record.id) > 0) {
				record.emptySince = 0;
				continue;
			}
			if (record.emptySince == 0) {
				record.emptySince = nowMs;
			}
			if (nowMs - record.emptySince >= graceMs) {
				idle.push_back(record.id);
			}
		}
	}
	return idle;
}
