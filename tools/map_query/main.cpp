////////////////////////////////////////////////////////////////////////
// map-query — load world.otbm via IOMap once, answer tile/town queries.
////////////////////////////////////////////////////////////////////////

#include "map_query_session.hpp"

#include <iostream>
#include <sstream>
#include <stdexcept>
#include <string>

namespace {

using json = nlohmann::json;

struct ToolOptions {
	std::string configPath;
	std::string otbmPath;
	std::string cmd;
};

void printUsage() {
	std::cerr
		<< "Usage:\n"
		<< "  map-query load --config PATH --otbm PATH\n"
		<< "  map-query query --config PATH --otbm PATH < request.json\n"
		<< "  map-query serve --config PATH --otbm PATH\n"
		<< "\n"
		<< "serve/query JSON ops: tiles-at, tiles-in-bounds, towns, teleports,\n"
		<< "  configure, tile-flags, team-fits, position-scores, flood-fill-floors,\n"
		<< "  flood-fill-floors-batch, flood-fill-from-pin, flood-fill-from-pins\n";
}

ToolOptions parseArgs(int argc, char **argv) {
	if (argc < 2) {
		throw std::runtime_error("missing command");
	}
	ToolOptions opts;
	opts.cmd = argv[1];
	for (int i = 2; i < argc; ++i) {
		const std::string arg = argv[i];
		if (arg == "--config" && i + 1 < argc) {
			opts.configPath = argv[++i];
		} else if (arg == "--otbm" && i + 1 < argc) {
			opts.otbmPath = argv[++i];
		} else {
			throw std::runtime_error("unknown arg: " + arg);
		}
	}
	if (opts.configPath.empty() || opts.otbmPath.empty()) {
		throw std::runtime_error("--config and --otbm are required");
	}
	return opts;
}

int runServe(const ToolOptions &opts) {
	auto session = map_query::MapQuerySession::create(opts.configPath, opts.otbmPath);
	std::cout << session->readyJson().dump() << '\n' << std::flush;

	std::string line;
	while (std::getline(std::cin, line)) {
		if (line.empty()) {
			continue;
		}
		try {
			const auto req = json::parse(line);
			std::cout << session->query(req).dump() << '\n' << std::flush;
		} catch (const std::exception &e) {
			std::cout << json { { "error", e.what() } }.dump() << '\n' << std::flush;
		}
	}
	return 0;
}

int runQuery(const ToolOptions &opts) {
	auto session = map_query::MapQuerySession::create(opts.configPath, opts.otbmPath);
	std::ostringstream input;
	input << std::cin.rdbuf();
	const auto req = json::parse(input.str());
	std::cout << session->query(req).dump() << '\n';
	return 0;
}

int runLoad(const ToolOptions &opts) {
	auto session = map_query::MapQuerySession::create(opts.configPath, opts.otbmPath);
	std::cout << session->readyJson().dump() << '\n';
	return 0;
}

} // namespace

int main(int argc, char **argv) {
	try {
		const auto opts = parseArgs(argc, argv);
		if (opts.cmd == "serve") {
			return runServe(opts);
		}
		if (opts.cmd == "query") {
			return runQuery(opts);
		}
		if (opts.cmd == "load") {
			return runLoad(opts);
		}
		throw std::runtime_error("unknown command: " + opts.cmd);
	} catch (const std::exception &e) {
		std::cerr << e.what() << '\n';
		printUsage();
		return 1;
	}
}
