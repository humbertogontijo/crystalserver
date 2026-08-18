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

#include "io/occupancy_mask.hpp"

#include <fstream>
#include <lzma.h>

namespace {
	constexpr size_t PACKED_PREFIX = 32;

	uint16_t readU16(const uint8_t* p) {
		return static_cast<uint16_t>(p[0] | (static_cast<uint16_t>(p[1]) << 8));
	}

	uint32_t readU32(const uint8_t* p) {
		return static_cast<uint32_t>(p[0])
			| (static_cast<uint32_t>(p[1]) << 8)
			| (static_cast<uint32_t>(p[2]) << 16)
			| (static_cast<uint32_t>(p[3]) << 24);
	}

	int32_t readI32(const uint8_t* p) {
		return static_cast<int32_t>(readU32(p));
	}

	bool decompressLzmaAlone(const uint8_t* src, size_t srcLen, std::vector<uint8_t> &out) {
		if (src == nullptr || srcLen == 0) {
			return false;
		}

		// Packed LZMA size field is often wrong; treat uncompressed size as unknown.
		std::vector<uint8_t> blob(src, src + srcLen);
		if (blob.size() >= 13) {
			for (size_t i = 0; i < 8; ++i) {
				blob[5 + i] = 0xFF;
			}
		}

		lzma_stream strm = LZMA_STREAM_INIT;
		const lzma_ret init = lzma_alone_decoder(&strm, UINT64_MAX);
		if (init != LZMA_OK) {
			lzma_end(&strm);
			return false;
		}

		out.assign(1 << 16, 0);
		strm.next_in = blob.data();
		strm.avail_in = blob.size();
		strm.next_out = out.data();
		strm.avail_out = out.size();

		while (true) {
			const lzma_ret ret = lzma_code(&strm, LZMA_FINISH);
			if (ret == LZMA_STREAM_END) {
				out.resize(out.size() - strm.avail_out);
				lzma_end(&strm);
				return true;
			}
			if (ret != LZMA_OK) {
				lzma_end(&strm);
				return false;
			}
			if (strm.avail_out > 0) {
				lzma_end(&strm);
				return false;
			}
			const size_t produced = out.size();
			out.resize(produced * 2);
			strm.next_out = out.data() + produced;
			strm.avail_out = out.size() - produced;
		}
	}
}

bool OccupancyMask::contains(int32_t worldX, int32_t worldY) const {
	const int32_t lx = worldX - originX;
	const int32_t ly = worldY - originY;
	if (lx < 0 || ly < 0 || lx >= width || ly >= height) {
		return false;
	}
	const size_t i = static_cast<size_t>(ly) * static_cast<size_t>(width) + static_cast<size_t>(lx);
	const size_t byteIndex = i >> 3;
	if (byteIndex >= bits.size()) {
		return false;
	}
	return (bits[byteIndex] & (1u << (i & 7))) != 0;
}

bool occupancyFromBmp(const uint8_t* bmp, size_t size, int32_t originX, int32_t originY, OccupancyMask &out) {
	if (bmp == nullptr || size < 26 || bmp[0] != 'B' || bmp[1] != 'M') {
		return false;
	}
	const uint32_t off = readU32(bmp + 10);
	const int32_t width = readI32(bmp + 18);
	const int32_t rawH = readI32(bmp + 22);
	const uint16_t bpp = readU16(bmp + 28);
	if (width <= 0 || rawH == 0 || bpp != 32) {
		return false;
	}
	const int32_t height = rawH < 0 ? -rawH : rawH;
	const bool topDown = rawH < 0;
	const size_t stride = static_cast<size_t>(width) * 4;
	const size_t pixelBytes = stride * static_cast<size_t>(height);
	if (off > size || size - off < pixelBytes) {
		return false;
	}

	OccupancyMask occ;
	occ.originX = originX;
	occ.originY = originY;
	occ.width = width;
	occ.height = height;
	occ.tiles = 0;
	occ.bits.assign((static_cast<size_t>(width) * static_cast<size_t>(height) + 7) / 8, 0);

	for (int32_t ly = 0; ly < height; ++ly) {
		const int32_t row = topDown ? ly : height - 1 - ly;
		const size_t rowOff = static_cast<size_t>(off) + static_cast<size_t>(row) * stride;
		for (int32_t lx = 0; lx < width; ++lx) {
			const uint8_t a = bmp[rowOff + static_cast<size_t>(lx) * 4 + 3];
			if (a == 0) {
				continue;
			}
			const size_t i = static_cast<size_t>(ly) * static_cast<size_t>(width) + static_cast<size_t>(lx);
			occ.bits[i >> 3] |= static_cast<uint8_t>(1u << (i & 7));
			++occ.tiles;
		}
	}
	out = std::move(occ);
	return true;
}

bool occupancyFromPacked(const uint8_t* packed, size_t size, int32_t originX, int32_t originY, OccupancyMask &out) {
	if (packed == nullptr || size <= PACKED_PREFIX) {
		return false;
	}
	std::vector<uint8_t> bmp;
	if (!decompressLzmaAlone(packed + PACKED_PREFIX, size - PACKED_PREFIX, bmp)) {
		return false;
	}
	return occupancyFromBmp(bmp.data(), bmp.size(), originX, originY, out);
}

bool loadOccupancyMaskFile(const std::string &path, int32_t originX, int32_t originY, OccupancyMask &out) {
	std::ifstream in(path, std::ios::binary);
	if (!in) {
		return false;
	}
	in.seekg(0, std::ios::end);
	const auto end = in.tellg();
	if (end <= 0) {
		return false;
	}
	in.seekg(0, std::ios::beg);
	std::vector<uint8_t> buf(static_cast<size_t>(end));
	if (!in.read(reinterpret_cast<char*>(buf.data()), static_cast<std::streamsize>(buf.size()))) {
		return false;
	}
	return occupancyFromPacked(buf.data(), buf.size(), originX, originY, out);
}
