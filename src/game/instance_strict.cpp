////////////////////////////////////////////////////////////////////////
// Crystal Server - an opensource roleplaying game
////////////////////////////////////////////////////////////////////////

#include "game/instance_strict.hpp"

#include "lib/metrics/metrics.hpp"
#include "lua/functions/lua_functions_loader.hpp"
#include "lua/scripts/luascript.hpp"

#include <parallel_hashmap/phmap.h>

namespace {
	// First occurrences per site are always logged; afterwards one in every N.
	constexpr uint64_t kAlwaysLog = 10;
	constexpr uint64_t kLogEvery = 500;

	phmap::flat_hash_map<std::string, uint64_t> &countsBySite() {
		static phmap::flat_hash_map<std::string, uint64_t> counts;
		return counts;
	}

	std::string luaTraceback(std::string_view message) {
		if (!Lua::hasScriptEnv()) {
			return {};
		}
		auto* env = Lua::getScriptEnv();
		auto* scriptInterface = env ? env->getScriptInterface() : nullptr;
		if (!scriptInterface) {
			return {};
		}
		return scriptInterface->getStackTrace(std::string(message));
	}
}

uint64_t instanceInferenceCount(std::string_view site) {
	const auto &counts = countsBySite();
	const auto it = counts.find(std::string(site));
	return it != counts.end() ? it->second : 0;
}

void reportInstanceInference(std::string_view site, std::string_view detail) {
	const uint64_t count = ++countsBySite()[std::string(site)];
	g_metrics().addCounter("instance_inferred_total", 1, { { "site", std::string(site) } });

	if (count <= kAlwaysLog || count % kLogEvery == 0) {
		const std::string message = fmt::format(
			"[Instance] {} without an explicit instance or actor scope{}{} (occurrence {})",
			site,
			detail.empty() ? "" : ": ",
			detail,
			count
		);
		const std::string traceback = luaTraceback(message);
		g_logger().warn("{}", traceback.empty() ? message : traceback);
	}
}
