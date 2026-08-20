////////////////////////////////////////////////////////////////////////
// CIP occupancy CLI — decode/encode 32-byte prefix + LZMA1-alone BMP masks.
////////////////////////////////////////////////////////////////////////

#include "io/occupancy_mask.hpp"

#include <nlohmann/json.hpp>

#include <cstdlib>
#include <fstream>
#include <iostream>
#include <sstream>
#include <stdexcept>
#include <string>
#include <vector>

namespace {

std::string base64Encode(const uint8_t* data, size_t len) {
	static constexpr char kTable[] =
		"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
	std::string out;
	out.reserve(((len + 2) / 3) * 4);
	for (size_t i = 0; i < len; i += 3) {
		const uint32_t n = (static_cast<uint32_t>(data[i]) << 16)
			| ((i + 1 < len ? static_cast<uint32_t>(data[i + 1]) : 0u) << 8)
			| (i + 2 < len ? static_cast<uint32_t>(data[i + 2]) : 0u);
		out.push_back(kTable[(n >> 18) & 63]);
		out.push_back(kTable[(n >> 12) & 63]);
		out.push_back(i + 1 < len ? kTable[(n >> 6) & 63] : '=');
		out.push_back(i + 2 < len ? kTable[n & 63] : '=');
	}
	return out;
}

int base64Value(char c) {
	if (c >= 'A' && c <= 'Z') {
		return c - 'A';
	}
	if (c >= 'a' && c <= 'z') {
		return c - 'a' + 26;
	}
	if (c >= '0' && c <= '9') {
		return c - '0' + 52;
	}
	if (c == '+') {
		return 62;
	}
	if (c == '/') {
		return 63;
	}
	return -1;
}

bool base64Decode(const std::string &in, std::vector<uint8_t> &out) {
	out.clear();
	out.reserve(in.size() * 3 / 4);
	int val = 0;
	int valb = -8;
	for (const char c : in) {
		if (c == '=' || c == '\n' || c == '\r' || c == ' ') {
			continue;
		}
		const int d = base64Value(c);
		if (d < 0) {
			return false;
		}
		val = (val << 6) + d;
		valb += 6;
		if (valb >= 0) {
			out.push_back(static_cast<uint8_t>((val >> valb) & 0xff));
			valb -= 8;
		}
	}
	return true;
}

nlohmann::json maskToJson(const OccupancyMask &occ) {
	return nlohmann::json {
		{ "originX", occ.originX },
		{ "originY", occ.originY },
		{ "width", occ.width },
		{ "height", occ.height },
		{ "tiles", occ.tiles },
		{ "bits", base64Encode(occ.bits.data(), occ.bits.size()) },
	};
}

std::string readAll(std::istream &in) {
	std::ostringstream ss;
	ss << in.rdbuf();
	return ss.str();
}

std::string readFileOrStdin(const std::string &path) {
	if (path == "-" || path.empty()) {
		return readAll(std::cin);
	}
	std::ifstream in(path);
	if (!in) {
		throw std::runtime_error("cannot read " + path);
	}
	return readAll(in);
}

void printUsage() {
	std::cerr
		<< "Usage:\n"
		<< "  cip-occupancy decode <file> [--origin-x N] [--origin-y N]\n"
		<< "  cip-occupancy decode-dir <dir> --manifest <path|->\n"
		<< "  cip-occupancy encode --width W --height H --origin-x X --origin-y Y\n"
		<< "                       --bits BASE64 --output PATH [--close]\n"
		<< "\n"
		<< "decode-dir manifest JSON: [{\"id\":N,\"file\":\"...\",\"originX\":N,\"originY\":N}, ...]\n"
		<< "decode / decode-dir output JSON occupancy (bits base64; closeInterior applied).\n";
}

int cmdDecode(int argc, char** argv) {
	if (argc < 1) {
		printUsage();
		return 2;
	}
	const std::string path = argv[0];
	int32_t originX = 0;
	int32_t originY = 0;
	for (int i = 1; i < argc; ++i) {
		const std::string arg = argv[i];
		if (arg == "--origin-x" && i + 1 < argc) {
			originX = static_cast<int32_t>(std::strtol(argv[++i], nullptr, 10));
		} else if (arg == "--origin-y" && i + 1 < argc) {
			originY = static_cast<int32_t>(std::strtol(argv[++i], nullptr, 10));
		} else {
			std::cerr << "unknown decode arg: " << arg << '\n';
			return 2;
		}
	}
	OccupancyMask occ;
	if (!loadOccupancyMaskFile(path, originX, originY, occ)) {
		std::cerr << "failed to decode " << path << '\n';
		return 1;
	}
	std::cout << maskToJson(occ).dump() << '\n';
	return 0;
}

int cmdDecodeDir(int argc, char** argv) {
	if (argc < 1) {
		printUsage();
		return 2;
	}
	const std::string dir = argv[0];
	std::string manifestPath;
	for (int i = 1; i < argc; ++i) {
		const std::string arg = argv[i];
		if (arg == "--manifest" && i + 1 < argc) {
			manifestPath = argv[++i];
		} else {
			std::cerr << "unknown decode-dir arg: " << arg << '\n';
			return 2;
		}
	}
	if (manifestPath.empty()) {
		std::cerr << "decode-dir requires --manifest <path|->\n";
		return 2;
	}

	nlohmann::json manifest;
	try {
		manifest = nlohmann::json::parse(readFileOrStdin(manifestPath));
	} catch (const std::exception &e) {
		std::cerr << "manifest parse failed: " << e.what() << '\n';
		return 1;
	}
	if (!manifest.is_array()) {
		std::cerr << "manifest must be a JSON array\n";
		return 1;
	}

	nlohmann::json out = nlohmann::json::object();
	for (const auto &entry : manifest) {
		const int id = entry.at("id").get<int>();
		const std::string file = entry.at("file").get<std::string>();
		const int32_t originX = entry.value("originX", 0);
		const int32_t originY = entry.value("originY", 0);
		const std::string path = dir + "/" + file;
		OccupancyMask occ;
		if (!loadOccupancyMaskFile(path, originX, originY, occ)) {
			std::cerr << "failed to decode " << path << '\n';
			return 1;
		}
		out[std::to_string(id)] = maskToJson(occ);
	}
	std::cout << out.dump() << '\n';
	return 0;
}

int cmdEncode(int argc, char** argv) {
	int32_t width = 0;
	int32_t height = 0;
	int32_t originX = 0;
	int32_t originY = 0;
	std::string bitsB64;
	std::string output;
	bool close = false;
	for (int i = 0; i < argc; ++i) {
		const std::string arg = argv[i];
		if (arg == "--width" && i + 1 < argc) {
			width = static_cast<int32_t>(std::strtol(argv[++i], nullptr, 10));
		} else if (arg == "--height" && i + 1 < argc) {
			height = static_cast<int32_t>(std::strtol(argv[++i], nullptr, 10));
		} else if (arg == "--origin-x" && i + 1 < argc) {
			originX = static_cast<int32_t>(std::strtol(argv[++i], nullptr, 10));
		} else if (arg == "--origin-y" && i + 1 < argc) {
			originY = static_cast<int32_t>(std::strtol(argv[++i], nullptr, 10));
		} else if (arg == "--bits" && i + 1 < argc) {
			bitsB64 = argv[++i];
		} else if (arg == "--output" && i + 1 < argc) {
			output = argv[++i];
		} else if (arg == "--close") {
			close = true;
		} else {
			std::cerr << "unknown encode arg: " << arg << '\n';
			return 2;
		}
	}
	if (width <= 0 || height <= 0 || bitsB64.empty() || output.empty()) {
		printUsage();
		return 2;
	}

	OccupancyMask occ;
	occ.originX = originX;
	occ.originY = originY;
	occ.width = width;
	occ.height = height;
	if (!base64Decode(bitsB64, occ.bits)) {
		std::cerr << "invalid --bits base64\n";
		return 1;
	}
	const size_t expected = (static_cast<size_t>(width) * static_cast<size_t>(height) + 7) / 8;
	if (occ.bits.size() < expected) {
		std::cerr << "bits too short for " << width << "x" << height << '\n';
		return 1;
	}
	occ.bits.resize(expected);
	occ.tiles = 0;
	for (size_t i = 0; i < static_cast<size_t>(width) * static_cast<size_t>(height); ++i) {
		if ((occ.bits[i >> 3] & (1u << (i & 7))) != 0) {
			++occ.tiles;
		}
	}
	if (close) {
		occupancyCloseInterior(occ);
	}
	if (!writeOccupancyMaskFile(output, occ)) {
		std::cerr << "failed to write " << output << '\n';
		return 1;
	}
	std::cout << nlohmann::json {
		{ "file", output },
		{ "width", occ.width },
		{ "height", occ.height },
		{ "tiles", occ.tiles },
	}.dump() << '\n';
	return 0;
}

} // namespace

int main(int argc, char** argv) {
	if (argc < 2) {
		printUsage();
		return 2;
	}
	const std::string cmd = argv[1];
	try {
		if (cmd == "decode") {
			return cmdDecode(argc - 2, argv + 2);
		}
		if (cmd == "decode-dir") {
			return cmdDecodeDir(argc - 2, argv + 2);
		}
		if (cmd == "encode") {
			return cmdEncode(argc - 2, argv + 2);
		}
	} catch (const std::exception &e) {
		std::cerr << e.what() << '\n';
		return 1;
	}
	printUsage();
	return 2;
}
