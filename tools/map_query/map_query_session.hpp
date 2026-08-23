////////////////////////////////////////////////////////////////////////
// In-process map-query session (shared by CLI and FFI).
////////////////////////////////////////////////////////////////////////

#pragma once

#include "geometry_engine.hpp"

#include <memory>
#include <nlohmann/json.hpp>
#include <string>

namespace map_query {

using json = nlohmann::json;

class MapQuerySession {
public:
	static std::unique_ptr<MapQuerySession> create(
		const std::string &configPath,
		const std::string &otbmPath
	);

	json readyJson() const;
	json query(const json &req);

private:
	MapQuerySession(std::unique_ptr<Map> map, int64_t loadMs);

	std::unique_ptr<Map> map_;
	int64_t loadMs_ = 0;
	GeometryEngine geometry_;
};

} // namespace map_query
