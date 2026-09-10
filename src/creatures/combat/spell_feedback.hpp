////////////////////////////////////////////////////////////////////////
// Crystal Server - an opensource roleplaying game
////////////////////////////////////////////////////////////////////////

#pragma once

#include <cstdint>

/** Suppress cancel messages + CONST_ME_POFF for silent/dry-run spell casts. */
namespace SpellFeedback {
inline thread_local uint32_t suppressDepth = 0;

struct Suppress {
	Suppress() {
		++suppressDepth;
	}
	~Suppress() {
		if (suppressDepth > 0) {
			--suppressDepth;
		}
	}
	Suppress(const Suppress &) = delete;
	Suppress &operator=(const Suppress &) = delete;
};

[[nodiscard]] inline bool suppressed() {
	return suppressDepth > 0;
}
} // namespace SpellFeedback
