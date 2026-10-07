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
#include <string>
#include <vector>

/**
 * Packed occupancy mask: 32-byte prefix + LZMA1-alone 32-bit BMP.
 * Opaque alpha (non-zero) means the world tile is inside the named area.
 * Standalone — no Game/Map dependency — so generate tooling can reuse it.
 */
struct OccupancyMask {
	int32_t originX = 0;
	int32_t originY = 0;
	int32_t width = 0;
	int32_t height = 0;
	uint32_t tiles = 0;
	std::vector<uint8_t> bits;

	[[nodiscard]] bool contains(int32_t worldX, int32_t worldY) const;
};

bool occupancyFromBmp(const uint8_t* bmp, size_t size, int32_t originX, int32_t originY, OccupancyMask &out);
bool occupancyFromPacked(const uint8_t* packed, size_t size, int32_t originX, int32_t originY, OccupancyMask &out);
bool loadOccupancyMaskFile(const std::string &path, int32_t originX, int32_t originY, OccupancyMask &out);

/** Encode occupancy as a bottom-up 32-bit BMP (opaque white = inside). */
bool occupancyToBmp(const OccupancyMask &occ, std::vector<uint8_t> &out);

/** Encode occupancy as 32-byte prefix + LZMA1-alone BMP (CIP catalog format). */
bool occupancyToPacked(const OccupancyMask &occ, std::vector<uint8_t> &out);

bool writeOccupancyMaskFile(const std::string &path, const OccupancyMask &occ);

bool lzmaAloneCompress(const uint8_t* src, size_t srcLen, std::vector<uint8_t> &out);
bool lzmaAloneDecompress(const uint8_t* src, size_t srcLen, std::vector<uint8_t> &out);

/** Fill enclosed holes + expand by radius without growing the outer silhouette. */
void occupancyCloseInterior(OccupancyMask &occ, int radius = 2);
