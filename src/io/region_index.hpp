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

#pragma once

#include <cstddef>
#include <cstdint>
#include <memory>
#include <string>
#include <unordered_map>
#include <vector>

/**
 * Multi-level subarea partition: tile -> region id, plus per-region metadata.
 *
 * Tiles live in sparse 32x32 chunks per floor; a chunk whose tiles all carry
 * one region (or none) is stored as a single value. Files are a small header
 * followed by an LZMA1-alone payload. Standalone (no Game/Map dependency) so
 * offline map tooling writes the same format the server reads.
 */
struct RegionRecord {
	uint32_t id = 0;
	/** Instance kind name (`city`, `settlement`, `hunt`, `wild`, `connector`, ...). */
	std::string kind;
	/** CIP subarea the region grew from (0 for wiki / connector regions). */
	uint32_t cipId = 0;
	std::string name;
	/** Connector regions list the regions they join; empty otherwise. */
	std::vector<uint32_t> owners;
};

class RegionIndex {
public:
	static constexpr int32_t CHUNK = 32;
	static constexpr int32_t CHUNK_TILES = CHUNK * CHUNK;

	[[nodiscard]] uint32_t at(int32_t x, int32_t y, int32_t z) const;
	void set(int32_t x, int32_t y, int32_t z, uint32_t regionId);

	/** Collapse single-valued chunks and build the dense chunk directory. */
	void compact();

	[[nodiscard]] const RegionRecord* region(uint32_t id) const;
	void addRegion(RegionRecord record);
	[[nodiscard]] const std::vector<RegionRecord> &regions() const {
		return records;
	}

	[[nodiscard]] size_t chunkCount() const {
		return chunks.size();
	}
	[[nodiscard]] bool empty() const {
		return chunks.empty();
	}
	void clear();

	bool save(const std::string &path) const;
	bool load(const std::string &path);

private:
	struct Chunk {
		uint32_t uniform = 0;
		std::unique_ptr<uint32_t[]> cells;
	};

	static uint32_t chunkKey(int32_t cx, int32_t cy, int32_t z);
	[[nodiscard]] const Chunk* findChunk(int32_t cx, int32_t cy, int32_t z) const;
	void buildDirectory();

	std::unordered_map<uint32_t, Chunk> chunks;
	std::vector<RegionRecord> records;
	std::unordered_map<uint32_t, size_t> recordById;

	// Dense directory over the chunk bounding box: index + 1 into `dirChunks`, 0 = none.
	int32_t dirMinCx = 0;
	int32_t dirMinCy = 0;
	int32_t dirWidth = 0;
	int32_t dirHeight = 0;
	std::vector<uint32_t> directory;
	std::vector<const Chunk*> dirChunks;
};
