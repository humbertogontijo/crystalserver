////////////////////////////////////////////////////////////////////////
// Crystal Server - an opensource roleplaying game
////////////////////////////////////////////////////////////////////////

#include "game/subarea_registry.hpp"

#include "config/configmanager.hpp"
#include "lib/logging/log_with_spd_log.hpp"

#include <algorithm>

SubareaRegistry &SubareaRegistry::getInstance() {
	static SubareaRegistry instance;
	return instance;
}

bool SubareaRegistry::load(const std::string &path) {
	resolved.clear();
	if (!index.load(path)) {
		g_logger().warn("[SubareaRegistry] {} missing or unreadable; open-world subarea instances are off", path);
		return false;
	}
	for (const auto &record : index.regions()) {
		resolved[record.id].kind = instanceKindFromName(record.kind).value_or(InstanceKind::Wild);
	}
	for (const auto &record : index.regions()) {
		auto &entry = resolved[record.id];
		if (entry.kind != InstanceKind::Connector) {
			entry.owners.emplace_back(entry.kind, record.id, 0);
			entry.main = entry.owners.front();
			continue;
		}
		for (const auto owner : record.owners) {
			entry.owners.emplace_back(kindOf(owner), owner, 0);
		}
		if (!entry.owners.empty()) {
			entry.main = *std::ranges::min_element(entry.owners, {}, &InstanceId::subareaId);
		}
	}
	g_logger().info("[SubareaRegistry] loaded {} regions ({} chunks)", index.regions().size(), index.chunkCount());
	return true;
}

bool SubareaRegistry::enabled() const {
	return loaded() && g_configManager().getBoolean(OPEN_WORLD_SUBAREA_INSTANCES);
}

const SubareaRegistry::Resolved* SubareaRegistry::resolve(uint32_t id) const {
	const auto it = resolved.find(id);
	return it != resolved.end() ? &it->second : nullptr;
}

InstanceKind SubareaRegistry::kindOf(uint32_t id) const {
	const auto* entry = resolve(id);
	return entry ? entry->kind : InstanceKind::Wild;
}

bool SubareaRegistry::allows(uint32_t regionId, InstanceId instanceId) const {
	if (regionId == 0 || instanceId.subareaId() == regionId) {
		return true;
	}
	const auto* entry = resolve(regionId);
	if (!entry || entry->kind != InstanceKind::Connector) {
		return false;
	}
	return std::ranges::any_of(entry->owners, [owner = instanceId.subareaId()](InstanceId id) { return id.subareaId() == owner; });
}

InstanceId SubareaRegistry::mainInstanceFor(uint32_t regionId) const {
	if (regionId == 0) {
		return InstanceId::World;
	}
	if (const auto* entry = resolve(regionId)) {
		return entry->main;
	}
	return InstanceId(InstanceKind::Wild, regionId, 0);
}

const std::vector<InstanceId> &SubareaRegistry::ownerInstancesFor(uint32_t regionId) const {
	static const std::vector<InstanceId> none;
	const auto* entry = regionId != 0 ? resolve(regionId) : nullptr;
	return entry ? entry->owners : none;
}
