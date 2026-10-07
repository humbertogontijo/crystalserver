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

namespace {
	bool localOn(const OccupancyMask &occ, int32_t lx, int32_t ly) {
		if (lx < 0 || ly < 0 || lx >= occ.width || ly >= occ.height) {
			return false;
		}
		const size_t i = static_cast<size_t>(ly) * static_cast<size_t>(occ.width) + static_cast<size_t>(lx);
		return (occ.bits[i >> 3] & (1u << (i & 7))) != 0;
	}

	void localSet(OccupancyMask &occ, int32_t lx, int32_t ly) {
		const size_t i = static_cast<size_t>(ly) * static_cast<size_t>(occ.width) + static_cast<size_t>(lx);
		const size_t byteIndex = i >> 3;
		const uint8_t bit = static_cast<uint8_t>(1u << (i & 7));
		if ((occ.bits[byteIndex] & bit) == 0) {
			occ.bits[byteIndex] |= bit;
			++occ.tiles;
		}
	}

	/** Empty pixels 4-connected to the image border. */
	std::vector<uint8_t> exteriorEmptyMask(const OccupancyMask &occ) {
		const size_t n = static_cast<size_t>(occ.width) * static_cast<size_t>(occ.height);
		std::vector<uint8_t> exterior(n, 0);
		std::vector<size_t> queue;
		queue.reserve(n / 8 + 8);

		auto tryPush = [&](int32_t lx, int32_t ly) {
			if (lx < 0 || ly < 0 || lx >= occ.width || ly >= occ.height) {
				return;
			}
			const size_t i = static_cast<size_t>(ly) * static_cast<size_t>(occ.width) + static_cast<size_t>(lx);
			if (exterior[i] != 0 || localOn(occ, lx, ly)) {
				return;
			}
			exterior[i] = 1;
			queue.push_back(i);
		};

		for (int32_t x = 0; x < occ.width; ++x) {
			tryPush(x, 0);
			tryPush(x, occ.height - 1);
		}
		for (int32_t y = 0; y < occ.height; ++y) {
			tryPush(0, y);
			tryPush(occ.width - 1, y);
		}
		while (!queue.empty()) {
			const size_t i = queue.back();
			queue.pop_back();
			const int32_t lx = static_cast<int32_t>(i % static_cast<size_t>(occ.width));
			const int32_t ly = static_cast<int32_t>(i / static_cast<size_t>(occ.width));
			tryPush(lx + 1, ly);
			tryPush(lx - 1, ly);
			tryPush(lx, ly + 1);
			tryPush(lx, ly - 1);
		}
		return exterior;
	}

	OccupancyMask dilate8(const OccupancyMask &occ) {
		OccupancyMask out;
		out.originX = occ.originX;
		out.originY = occ.originY;
		out.width = occ.width;
		out.height = occ.height;
		out.tiles = 0;
		out.bits.assign(occ.bits.size(), 0);
		for (int32_t ly = 0; ly < occ.height; ++ly) {
			for (int32_t lx = 0; lx < occ.width; ++lx) {
				bool on = false;
				for (int32_t dy = -1; dy <= 1 && !on; ++dy) {
					for (int32_t dx = -1; dx <= 1; ++dx) {
						if (localOn(occ, lx + dx, ly + dy)) {
							on = true;
							break;
						}
					}
				}
				if (on) {
					localSet(out, lx, ly);
				}
			}
		}
		return out;
	}

	OccupancyMask erode8(const OccupancyMask &occ) {
		OccupancyMask out;
		out.originX = occ.originX;
		out.originY = occ.originY;
		out.width = occ.width;
		out.height = occ.height;
		out.tiles = 0;
		out.bits.assign(occ.bits.size(), 0);
		for (int32_t ly = 0; ly < occ.height; ++ly) {
			for (int32_t lx = 0; lx < occ.width; ++lx) {
				bool keep = true;
				for (int32_t dy = -1; dy <= 1 && keep; ++dy) {
					for (int32_t dx = -1; dx <= 1; ++dx) {
						if (!localOn(occ, lx + dx, ly + dy)) {
							keep = false;
							break;
						}
					}
				}
				if (keep) {
					localSet(out, lx, ly);
				}
			}
		}
		return out;
	}

	OccupancyMask fillEnclosedHoles(const OccupancyMask &occ) {
		const auto exterior = exteriorEmptyMask(occ);
		const size_t n = static_cast<size_t>(occ.width) * static_cast<size_t>(occ.height);
		OccupancyMask filled;
		filled.originX = occ.originX;
		filled.originY = occ.originY;
		filled.width = occ.width;
		filled.height = occ.height;
		filled.tiles = 0;
		filled.bits.assign(occ.bits.size(), 0);
		for (size_t i = 0; i < n; ++i) {
			const int32_t lx = static_cast<int32_t>(i % static_cast<size_t>(occ.width));
			const int32_t ly = static_cast<int32_t>(i / static_cast<size_t>(occ.width));
			if (localOn(occ, lx, ly) || exterior[i] == 0) {
				localSet(filled, lx, ly);
			}
		}
		return filled;
	}

	void unionInto(OccupancyMask &dst, const OccupancyMask &src) {
		const size_t n = static_cast<size_t>(dst.width) * static_cast<size_t>(dst.height);
		for (size_t i = 0; i < n; ++i) {
			const int32_t lx = static_cast<int32_t>(i % static_cast<size_t>(dst.width));
			const int32_t ly = static_cast<int32_t>(i / static_cast<size_t>(dst.width));
			if (localOn(src, lx, ly)) {
				localSet(dst, lx, ly);
			}
		}
	}
}

/**
 * Morphological close: fill enclosed holes and narrow exterior inlets
 * (e.g. drawbridge bays). Never drops originally occupied tiles.
 * Matches packages/asset-pipeline occupancyCloseInterior.
 */
void occupancyCloseInterior(OccupancyMask &occ, int radius) {
	if (occ.width <= 0 || occ.height <= 0 || occ.bits.empty()) {
		return;
	}
	const OccupancyMask original = occ;
	const int r = radius < 0 ? 0 : radius;
	OccupancyMask cur = fillEnclosedHoles(occ);
	for (int step = 0; step < r; ++step) {
		cur = dilate8(cur);
	}
	cur = fillEnclosedHoles(cur);
	for (int step = 0; step < r; ++step) {
		cur = erode8(cur);
	}
	unionInto(cur, original);
	occ = fillEnclosedHoles(cur);
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
	if (!occupancyFromBmp(bmp.data(), bmp.size(), originX, originY, out)) {
		return false;
	}
	occupancyCloseInterior(out);
	return true;
}

namespace {
	void writeU16(uint8_t* p, uint16_t value) {
		p[0] = static_cast<uint8_t>(value & 0xff);
		p[1] = static_cast<uint8_t>((value >> 8) & 0xff);
	}

	void writeU32(uint8_t* p, uint32_t value) {
		p[0] = static_cast<uint8_t>(value & 0xff);
		p[1] = static_cast<uint8_t>((value >> 8) & 0xff);
		p[2] = static_cast<uint8_t>((value >> 16) & 0xff);
		p[3] = static_cast<uint8_t>((value >> 24) & 0xff);
	}

	void writeI32(uint8_t* p, int32_t value) {
		writeU32(p, static_cast<uint32_t>(value));
	}

	bool compressLzmaAlone(const uint8_t* src, size_t srcLen, std::vector<uint8_t> &out) {
		if (src == nullptr || srcLen == 0) {
			return false;
		}

		lzma_options_lzma opt;
		if (lzma_lzma_preset(&opt, LZMA_PRESET_DEFAULT)) {
			return false;
		}

		lzma_stream strm = LZMA_STREAM_INIT;
		if (lzma_alone_encoder(&strm, &opt) != LZMA_OK) {
			lzma_end(&strm);
			return false;
		}

		out.assign(1 << 16, 0);
		strm.next_in = const_cast<uint8_t*>(src);
		strm.avail_in = srcLen;
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

bool occupancyToBmp(const OccupancyMask &occ, std::vector<uint8_t> &out) {
	if (occ.width <= 0 || occ.height <= 0) {
		return false;
	}
	constexpr uint32_t off = 54;
	const size_t stride = static_cast<size_t>(occ.width) * 4;
	out.assign(static_cast<size_t>(off) + stride * static_cast<size_t>(occ.height), 0);
	out[0] = 'B';
	out[1] = 'M';
	writeU32(out.data() + 2, static_cast<uint32_t>(out.size()));
	writeU32(out.data() + 10, off);
	writeU32(out.data() + 14, 40);
	writeI32(out.data() + 18, occ.width);
	writeI32(out.data() + 22, occ.height); // bottom-up
	writeU16(out.data() + 26, 1);
	writeU16(out.data() + 28, 32);
	for (int32_t ly = 0; ly < occ.height; ++ly) {
		const int32_t bmpRow = occ.height - 1 - ly;
		const size_t rowOff = static_cast<size_t>(off) + static_cast<size_t>(bmpRow) * stride;
		for (int32_t lx = 0; lx < occ.width; ++lx) {
			if (!localOn(occ, lx, ly)) {
				continue;
			}
			const size_t p = rowOff + static_cast<size_t>(lx) * 4;
			out[p] = 255;
			out[p + 1] = 255;
			out[p + 2] = 255;
			out[p + 3] = 255;
		}
	}
	return true;
}

bool occupancyToPacked(const OccupancyMask &occ, std::vector<uint8_t> &out) {
	std::vector<uint8_t> bmp;
	if (!occupancyToBmp(occ, bmp)) {
		return false;
	}
	std::vector<uint8_t> blob;
	if (!compressLzmaAlone(bmp.data(), bmp.size(), blob)) {
		return false;
	}
	out.assign(PACKED_PREFIX, 0);
	out.insert(out.end(), blob.begin(), blob.end());
	return true;
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

bool writeOccupancyMaskFile(const std::string &path, const OccupancyMask &occ) {
	std::vector<uint8_t> packed;
	if (!occupancyToPacked(occ, packed)) {
		return false;
	}
	std::ofstream out(path, std::ios::binary);
	if (!out) {
		return false;
	}
	out.write(reinterpret_cast<const char*>(packed.data()), static_cast<std::streamsize>(packed.size()));
	return static_cast<bool>(out);
}
