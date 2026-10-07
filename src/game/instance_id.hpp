////////////////////////////////////////////////////////////////////////
// Crystal Server - an opensource roleplaying game
////////////////////////////////////////////////////////////////////////

#pragma once

#include <cstddef>
#include <cstdint>
#include <functional>
#include <optional>
#include <string>
#include <string_view>

/**
 * What an instance is for. Open-world kinds come from the subarea partition
 * (regions.generated.json); private kinds come from the allocator.
 */
enum class InstanceKind : uint8_t {
	World = 0,
	City = 1,
	Settlement = 2,
	Hub = 3,
	Wild = 4,
	Hunt = 5,
	Connector = 6,
	Lobby = 7,
	Raid = 8,
	Arena = 9,
	WorldBoss = 10,
	Soulpit = 11,

	Count,
	Any = 0xFF,
};

[[nodiscard]] std::string_view instanceKindName(InstanceKind kind);
[[nodiscard]] std::optional<InstanceKind> instanceKindFromName(std::string_view name);

/** Shared open-world layers (players switch between them by walking). */
[[nodiscard]] constexpr bool isOpenWorldKind(InstanceKind kind) noexcept {
	switch (kind) {
		case InstanceKind::City:
		case InstanceKind::Settlement:
		case InstanceKind::Wild:
		case InstanceKind::Hunt:
		case InstanceKind::Connector:
			return true;
		default:
			return false;
	}
}

/** City / settlement: one area fence covers every channel of {kind, subarea}. */
[[nodiscard]] constexpr bool isAreaKind(InstanceKind kind) noexcept {
	return kind == InstanceKind::City || kind == InstanceKind::Settlement;
}

/** Kinds that only exist as private sessions (lobby, raid, arena, world boss, soul pit). */
[[nodiscard]] constexpr bool isPrivateOnlyKind(InstanceKind kind) noexcept {
	switch (kind) {
		case InstanceKind::Lobby:
		case InstanceKind::Raid:
		case InstanceKind::Arena:
		case InstanceKind::WorldBoss:
		case InstanceKind::Soulpit:
			return true;
		default:
			return false;
	}
}

/** Kinds whose channel 0 is an always-live public layer (hub and open-world kinds). */
[[nodiscard]] constexpr bool hasImplicitMainChannel(InstanceKind kind) noexcept {
	return kind == InstanceKind::Hub || isOpenWorldKind(kind);
}

/**
 * Instance layer an item or creature lives in: {kind, subareaId, channel}.
 * Two things share an instance only when all three match. Construction is
 * explicit so a count, subtype or literal cannot silently land in an instance
 * parameter; InstanceId::World is the shared map-template layer.
 */
class InstanceId {
public:
	static const InstanceId World;
	/** Spectator / filter wildcard: matches every instance. Never stored on a thing. */
	static const InstanceId Any;

	constexpr InstanceId() noexcept = default;

	constexpr InstanceId(InstanceKind kind, uint32_t subareaId, uint16_t channel) noexcept :
		packed((static_cast<uint64_t>(kind) << 48) | (static_cast<uint64_t>(channel) << 32) | subareaId) { }

	[[nodiscard]] constexpr uint64_t value() const noexcept {
		return packed;
	}

	[[nodiscard]] constexpr InstanceKind kind() const noexcept {
		return static_cast<InstanceKind>((packed >> 48) & 0xFF);
	}

	[[nodiscard]] constexpr uint32_t subareaId() const noexcept {
		return static_cast<uint32_t>(packed & 0xFFFFFFFFu);
	}

	[[nodiscard]] constexpr uint16_t channel() const noexcept {
		return static_cast<uint16_t>((packed >> 32) & 0xFFFF);
	}

	/** Same kind and subarea, different channel. */
	[[nodiscard]] constexpr InstanceId withChannel(uint16_t newChannel) const noexcept {
		return InstanceId(kind(), subareaId(), newChannel);
	}

	[[nodiscard]] constexpr bool isWorld() const noexcept {
		return packed == 0;
	}

	[[nodiscard]] constexpr bool isAny() const noexcept {
		return kind() == InstanceKind::Any;
	}

	/** A real layer: neither the World template nor the Any wildcard. */
	[[nodiscard]] constexpr bool isConcrete() const noexcept {
		return !isWorld() && !isAny();
	}

	/** Channel 0 of a kind with an implicit, always-live main layer. */
	[[nodiscard]] constexpr bool isImplicitMain() const noexcept {
		return channel() == 0 && hasImplicitMainChannel(kind());
	}

	/** Canonical text form `kind:subareaId:channel` (Lua handle, logs, KV). */
	[[nodiscard]] std::string toKey() const;
	[[nodiscard]] static std::optional<InstanceId> fromKey(std::string_view key);

	friend constexpr bool operator==(InstanceId a, InstanceId b) noexcept {
		return a.packed == b.packed;
	}
	friend constexpr bool operator!=(InstanceId a, InstanceId b) noexcept {
		return a.packed != b.packed;
	}
	friend constexpr bool operator<(InstanceId a, InstanceId b) noexcept {
		return a.packed < b.packed;
	}

	friend std::string format_as(InstanceId instanceId) {
		return instanceId.toKey();
	}

private:
	uint64_t packed = 0;
};

inline constexpr InstanceId InstanceId::World {};
inline constexpr InstanceId InstanceId::Any { InstanceKind::Any, 0xFFFFFFFFu, 0xFFFF };

template <>
struct std::hash<InstanceId> {
	size_t operator()(const InstanceId &id) const noexcept {
		return std::hash<uint64_t> {}(id.value());
	}
};
