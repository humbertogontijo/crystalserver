////////////////////////////////////////////////////////////////////////
// Crystal Server - an opensource roleplaying game
////////////////////////////////////////////////////////////////////////

#pragma once

#include <cstdint>

/**
 * Instance layer an item or creature is born in. Construction is explicit so a
 * count, subtype or literal cannot silently land in an instance parameter;
 * use InstanceId::World for the shared open-world layer. Reads convert back to
 * uint32_t for comparisons, map keys and Lua.
 */
class InstanceId {
public:
	static const InstanceId World;

	constexpr explicit InstanceId(uint32_t id) noexcept :
		id(id) { }

	constexpr uint32_t value() const noexcept {
		return id;
	}

	constexpr operator uint32_t() const noexcept {
		return id;
	}

	constexpr bool isWorld() const noexcept {
		return id == 0;
	}

	friend constexpr uint32_t format_as(InstanceId instanceId) noexcept {
		return instanceId.id;
	}

private:
	uint32_t id;
};

inline constexpr InstanceId InstanceId::World { 0 };
