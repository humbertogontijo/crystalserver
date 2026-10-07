////////////////////////////////////////////////////////////////////////
// Crystal Server - an opensource roleplaying game
////////////////////////////////////////////////////////////////////////

#include "game/instance_id.hpp"

#include <array>
#include <charconv>

namespace {
	constexpr std::array<std::string_view, static_cast<size_t>(InstanceKind::Count)> kInstanceKindNames {
		"world",
		"city",
		"settlement",
		"hub",
		"wild",
		"hunt",
		"connector",
		"lobby",
		"raid",
		"arena",
		"worldboss",
		"soulpit",
	};

	template <typename T>
	bool parseInstanceKeyNumber(std::string_view text, T &out) {
		if (text.empty()) {
			return false;
		}
		const auto* end = text.data() + text.size();
		const auto [ptr, ec] = std::from_chars(text.data(), end, out);
		return ec == std::errc {} && ptr == end;
	}
}

std::string_view instanceKindName(InstanceKind kind) {
	if (kind == InstanceKind::Any) {
		return "any";
	}
	const auto index = static_cast<size_t>(kind);
	return index < kInstanceKindNames.size() ? kInstanceKindNames[index] : "unknown";
}

std::optional<InstanceKind> instanceKindFromName(std::string_view name) {
	for (size_t i = 0; i < kInstanceKindNames.size(); ++i) {
		if (kInstanceKindNames[i] == name) {
			return static_cast<InstanceKind>(i);
		}
	}
	return std::nullopt;
}

std::string InstanceId::toKey() const {
	std::string key(instanceKindName(kind()));
	key.push_back(':');
	key.append(std::to_string(subareaId()));
	key.push_back(':');
	key.append(std::to_string(channel()));
	return key;
}

std::optional<InstanceId> InstanceId::fromKey(std::string_view key) {
	const auto first = key.find(':');
	if (first == std::string_view::npos) {
		return std::nullopt;
	}
	const auto second = key.find(':', first + 1);
	if (second == std::string_view::npos) {
		return std::nullopt;
	}
	const auto kind = instanceKindFromName(key.substr(0, first));
	if (!kind) {
		return std::nullopt;
	}
	uint32_t subareaId = 0;
	uint16_t channel = 0;
	if (!parseInstanceKeyNumber(key.substr(first + 1, second - first - 1), subareaId) || !parseInstanceKeyNumber(key.substr(second + 1), channel)) {
		return std::nullopt;
	}
	if (*kind == InstanceKind::World && (subareaId != 0 || channel != 0)) {
		return std::nullopt;
	}
	return InstanceId(*kind, subareaId, channel);
}
