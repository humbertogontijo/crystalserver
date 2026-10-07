////////////////////////////////////////////////////////////////////////
// Crystal Server - an opensource roleplaying game
////////////////////////////////////////////////////////////////////////
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU General Public License as published by
// the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.
//
// This program is distributed in the hope that it will be useful,
// but WITHOUT ANY WARRANTY; without even the implied warranty of
// MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
// GNU General Public License for more details.
//
// You should have received a copy of the GNU General Public License
// along with this program.  If not, see <http://www.gnu.org/licenses/>.
////////////////////////////////////////////////////////////////////////

#include "io/region_index.hpp"

#include "io/occupancy_mask.hpp"

#include <algorithm>
#include <cstring>
#include <fstream>
#include <limits>

namespace {
	constexpr char MAGIC[4] = { 'I', 'D', 'R', 'X' };
	constexpr uint32_t VERSION = 1;
	constexpr size_t HEADER = 12;
	constexpr int32_t FLOORS = 16;

	class Writer {
	public:
		std::vector<uint8_t> buf;

		void u8(uint8_t v) {
			buf.push_back(v);
		}
		void u16(uint16_t v) {
			buf.push_back(static_cast<uint8_t>(v & 0xFF));
			buf.push_back(static_cast<uint8_t>(v >> 8));
		}
		void u32(uint32_t v) {
			for (int i = 0; i < 4; ++i) {
				buf.push_back(static_cast<uint8_t>((v >> (8 * i)) & 0xFF));
			}
		}
		void str(const std::string &s, size_t maxLen) {
			const auto len = std::min(s.size(), maxLen);
			if (maxLen <= std::numeric_limits<uint8_t>::max()) {
				u8(static_cast<uint8_t>(len));
			} else {
				u16(static_cast<uint16_t>(len));
			}
			buf.insert(buf.end(), s.begin(), s.begin() + static_cast<std::ptrdiff_t>(len));
		}
	};

	class Reader {
	public:
		Reader(const uint8_t* data, size_t size) :
			p(data), end(data + size) { }

		bool ok = true;

		uint8_t u8() {
			if (!need(1)) {
				return 0;
			}
			return *p++;
		}
		uint16_t u16() {
			if (!need(2)) {
				return 0;
			}
			const auto v = static_cast<uint16_t>(p[0] | (p[1] << 8));
			p += 2;
			return v;
		}
		uint32_t u32() {
			if (!need(4)) {
				return 0;
			}
			const auto v = static_cast<uint32_t>(p[0]) | (static_cast<uint32_t>(p[1]) << 8) | (static_cast<uint32_t>(p[2]) << 16) | (static_cast<uint32_t>(p[3]) << 24);
			p += 4;
			return v;
		}
		std::string str(size_t len) {
			if (!need(len)) {
				return {};
			}
			std::string s(reinterpret_cast<const char*>(p), len);
			p += len;
			return s;
		}

	private:
		bool need(size_t n) {
			if (!ok || static_cast<size_t>(end - p) < n) {
				ok = false;
				return false;
			}
			return true;
		}

		const uint8_t* p;
		const uint8_t* end;
	};
}

uint32_t RegionIndex::chunkKey(int32_t cx, int32_t cy, int32_t z) {
	return (static_cast<uint32_t>(cx & 0x7FF) << 15) | (static_cast<uint32_t>(cy & 0x7FF) << 4) | static_cast<uint32_t>(z & 0xF);
}

const RegionIndex::Chunk* RegionIndex::findChunk(int32_t cx, int32_t cy, int32_t z) const {
	if (!directory.empty()) {
		const int32_t lx = cx - dirMinCx;
		const int32_t ly = cy - dirMinCy;
		if (lx < 0 || ly < 0 || lx >= dirWidth || ly >= dirHeight) {
			return nullptr;
		}
		const auto slot = directory[(static_cast<size_t>(z) * dirHeight + ly) * dirWidth + lx];
		return slot == 0 ? nullptr : dirChunks[slot - 1];
	}
	const auto it = chunks.find(chunkKey(cx, cy, z));
	return it == chunks.end() ? nullptr : &it->second;
}

uint32_t RegionIndex::at(int32_t x, int32_t y, int32_t z) const {
	if (x < 0 || y < 0 || z < 0 || z >= FLOORS) {
		return 0;
	}
	const auto* chunk = findChunk(x / CHUNK, y / CHUNK, z);
	if (chunk == nullptr) {
		return 0;
	}
	if (!chunk->cells) {
		return chunk->uniform;
	}
	return chunk->cells[static_cast<size_t>(y % CHUNK) * CHUNK + static_cast<size_t>(x % CHUNK)];
}

void RegionIndex::set(int32_t x, int32_t y, int32_t z, uint32_t regionId) {
	if (x < 0 || y < 0 || z < 0 || z >= FLOORS) {
		return;
	}
	directory.clear();
	dirChunks.clear();
	auto &chunk = chunks[chunkKey(x / CHUNK, y / CHUNK, z)];
	if (!chunk.cells) {
		if (chunk.uniform == regionId) {
			return;
		}
		chunk.cells = std::make_unique<uint32_t[]>(CHUNK_TILES);
		std::fill_n(chunk.cells.get(), CHUNK_TILES, chunk.uniform);
	}
	chunk.cells[static_cast<size_t>(y % CHUNK) * CHUNK + static_cast<size_t>(x % CHUNK)] = regionId;
}

void RegionIndex::compact() {
	for (auto it = chunks.begin(); it != chunks.end();) {
		auto &chunk = it->second;
		if (chunk.cells) {
			const uint32_t first = chunk.cells[0];
			if (std::all_of(chunk.cells.get(), chunk.cells.get() + CHUNK_TILES, [first](uint32_t v) { return v == first; })) {
				chunk.uniform = first;
				chunk.cells.reset();
			}
		}
		if (!chunk.cells && chunk.uniform == 0) {
			it = chunks.erase(it);
		} else {
			++it;
		}
	}
	buildDirectory();
}

void RegionIndex::buildDirectory() {
	directory.clear();
	dirChunks.clear();
	if (chunks.empty()) {
		return;
	}
	int32_t minCx = std::numeric_limits<int32_t>::max();
	int32_t minCy = std::numeric_limits<int32_t>::max();
	int32_t maxCx = 0;
	int32_t maxCy = 0;
	for (const auto &[key, chunk] : chunks) {
		const auto cx = static_cast<int32_t>((key >> 15) & 0x7FF);
		const auto cy = static_cast<int32_t>((key >> 4) & 0x7FF);
		minCx = std::min(minCx, cx);
		minCy = std::min(minCy, cy);
		maxCx = std::max(maxCx, cx);
		maxCy = std::max(maxCy, cy);
	}
	dirMinCx = minCx;
	dirMinCy = minCy;
	dirWidth = maxCx - minCx + 1;
	dirHeight = maxCy - minCy + 1;
	directory.assign(static_cast<size_t>(dirWidth) * dirHeight * FLOORS, 0);
	dirChunks.reserve(chunks.size());
	for (const auto &[key, chunk] : chunks) {
		const auto cx = static_cast<int32_t>((key >> 15) & 0x7FF);
		const auto cy = static_cast<int32_t>((key >> 4) & 0x7FF);
		const auto z = static_cast<int32_t>(key & 0xF);
		dirChunks.push_back(&chunk);
		directory[(static_cast<size_t>(z) * dirHeight + (cy - dirMinCy)) * dirWidth + (cx - dirMinCx)] = static_cast<uint32_t>(dirChunks.size());
	}
}

const RegionRecord* RegionIndex::region(uint32_t id) const {
	const auto it = recordById.find(id);
	return it == recordById.end() ? nullptr : &records[it->second];
}

void RegionIndex::addRegion(RegionRecord record) {
	const auto it = recordById.find(record.id);
	if (it != recordById.end()) {
		records[it->second] = std::move(record);
		return;
	}
	recordById.emplace(record.id, records.size());
	records.push_back(std::move(record));
}

void RegionIndex::clear() {
	chunks.clear();
	records.clear();
	recordById.clear();
	directory.clear();
	dirChunks.clear();
}

bool RegionIndex::save(const std::string &path) const {
	Writer w;
	w.u32(static_cast<uint32_t>(records.size()));
	for (const auto &r : records) {
		w.u32(r.id);
		w.str(r.kind, std::numeric_limits<uint8_t>::max());
		w.u32(r.cipId);
		w.str(r.name, std::numeric_limits<uint16_t>::max());
		w.u16(static_cast<uint16_t>(std::min<size_t>(r.owners.size(), std::numeric_limits<uint16_t>::max())));
		for (size_t i = 0; i < r.owners.size() && i < std::numeric_limits<uint16_t>::max(); ++i) {
			w.u32(r.owners[i]);
		}
	}
	std::vector<uint32_t> keys;
	keys.reserve(chunks.size());
	for (const auto &[key, chunk] : chunks) {
		keys.push_back(key);
	}
	std::ranges::sort(keys);
	w.u32(static_cast<uint32_t>(keys.size()));
	for (const auto key : keys) {
		const auto &chunk = chunks.at(key);
		w.u32(key);
		if (!chunk.cells) {
			w.u8(0);
			w.u32(chunk.uniform);
			continue;
		}
		w.u8(1);
		for (int32_t i = 0; i < CHUNK_TILES; ++i) {
			w.u32(chunk.cells[i]);
		}
	}

	std::vector<uint8_t> blob;
	if (!lzmaAloneCompress(w.buf.data(), w.buf.size(), blob)) {
		return false;
	}
	std::ofstream out(path, std::ios::binary);
	if (!out) {
		return false;
	}
	Writer header;
	header.buf.insert(header.buf.end(), std::begin(MAGIC), std::end(MAGIC));
	header.u32(VERSION);
	header.u32(static_cast<uint32_t>(w.buf.size()));
	out.write(reinterpret_cast<const char*>(header.buf.data()), static_cast<std::streamsize>(header.buf.size()));
	out.write(reinterpret_cast<const char*>(blob.data()), static_cast<std::streamsize>(blob.size()));
	return static_cast<bool>(out);
}

bool RegionIndex::load(const std::string &path) {
	clear();
	std::ifstream in(path, std::ios::binary);
	if (!in) {
		return false;
	}
	std::vector<uint8_t> file((std::istreambuf_iterator<char>(in)), std::istreambuf_iterator<char>());
	if (file.size() <= HEADER || std::memcmp(file.data(), MAGIC, sizeof(MAGIC)) != 0) {
		return false;
	}
	Reader header(file.data() + sizeof(MAGIC), HEADER - sizeof(MAGIC));
	if (header.u32() != VERSION) {
		return false;
	}
	const auto rawSize = header.u32();
	std::vector<uint8_t> payload;
	if (!lzmaAloneDecompress(file.data() + HEADER, file.size() - HEADER, payload) || payload.size() != rawSize) {
		return false;
	}

	Reader r(payload.data(), payload.size());
	const auto regionCount = r.u32();
	for (uint32_t i = 0; i < regionCount && r.ok; ++i) {
		RegionRecord rec;
		rec.id = r.u32();
		rec.kind = r.str(r.u8());
		rec.cipId = r.u32();
		rec.name = r.str(r.u16());
		const auto owners = r.u16();
		rec.owners.reserve(owners);
		for (uint16_t o = 0; o < owners; ++o) {
			rec.owners.push_back(r.u32());
		}
		addRegion(std::move(rec));
	}
	const auto chunkCount = r.u32();
	for (uint32_t i = 0; i < chunkCount && r.ok; ++i) {
		const auto key = r.u32();
		Chunk chunk;
		if (r.u8() == 0) {
			chunk.uniform = r.u32();
		} else {
			chunk.cells = std::make_unique<uint32_t[]>(CHUNK_TILES);
			for (int32_t c = 0; c < CHUNK_TILES; ++c) {
				chunk.cells[c] = r.u32();
			}
		}
		chunks.emplace(key, std::move(chunk));
	}
	if (!r.ok) {
		clear();
		return false;
	}
	buildDirectory();
	return true;
}
