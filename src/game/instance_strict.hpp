////////////////////////////////////////////////////////////////////////
// Crystal Server - an opensource roleplaying game
////////////////////////////////////////////////////////////////////////

#pragma once

#include <cstdint>
#include <string_view>

/**
 * An operation at `site` had no explicit instance and no actor scope. Counts
 * `instance_inferred_total{site}` and logs a rate-limited warning with the Lua traceback
 * when a script is running. The instance is never guessed from the position: the caller
 * refuses or falls back to the all-layer behavior.
 */
void reportInstanceInference(std::string_view site, std::string_view detail = {});

/** Total inferences reported for `site` since start (tests / GM diagnostics). */
[[nodiscard]] uint64_t instanceInferenceCount(std::string_view site);
