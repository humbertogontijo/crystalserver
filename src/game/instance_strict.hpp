////////////////////////////////////////////////////////////////////////
// Crystal Server - an opensource roleplaying game
////////////////////////////////////////////////////////////////////////

#pragma once

#include <cstdint>
#include <string_view>

/**
 * An instance had to be inferred (no explicit id, no actor scope) at `site`.
 * Counts `instance_inferred_total{site}`, logs a rate-limited warning with the Lua
 * traceback when a script is running, and returns true when `instanceStrict` is on —
 * the caller must then refuse the operation instead of guessing.
 */
bool reportInstanceInference(std::string_view site, std::string_view detail = {});

[[nodiscard]] bool isInstanceStrict();

/** Total inferences reported for `site` since start (tests / GM diagnostics). */
[[nodiscard]] uint64_t instanceInferenceCount(std::string_view site);
