#include "pch.hpp"

#include <boost/ut.hpp>
#include <filesystem>
#include <fstream>
#include <vector>

#include "io/occupancy_mask.hpp"

using namespace boost::ut;

namespace {
	std::vector<uint8_t> readAll(const std::filesystem::path &path) {
		std::ifstream in(path, std::ios::binary);
		expect(in.good()) << path.string();
		in.seekg(0, std::ios::end);
		const auto end = in.tellg();
		in.seekg(0, std::ios::beg);
		std::vector<uint8_t> buf(static_cast<size_t>(end));
		in.read(reinterpret_cast<char*>(buf.data()), static_cast<std::streamsize>(buf.size()));
		return buf;
	}

	std::vector<uint8_t> bmp32(int32_t width, int32_t height, const std::vector<uint8_t> &alphaTopDown) {
		const uint32_t off = 54;
		const size_t stride = static_cast<size_t>(width) * 4;
		std::vector<uint8_t> out(off + stride * static_cast<size_t>(height), 0);
		out[0] = 'B';
		out[1] = 'M';
		const uint32_t size = static_cast<uint32_t>(out.size());
		out[2] = static_cast<uint8_t>(size);
		out[3] = static_cast<uint8_t>(size >> 8);
		out[4] = static_cast<uint8_t>(size >> 16);
		out[5] = static_cast<uint8_t>(size >> 24);
		out[10] = 54;
		out[14] = 40;
		out[18] = static_cast<uint8_t>(width);
		out[22] = static_cast<uint8_t>(height); // bottom-up
		out[26] = 1;
		out[28] = 32;
		for (int32_t ly = 0; ly < height; ++ly) {
			const int32_t bmpRow = height - 1 - ly;
			for (int32_t lx = 0; lx < width; ++lx) {
				const uint8_t a = alphaTopDown[static_cast<size_t>(ly) * static_cast<size_t>(width) + static_cast<size_t>(lx)];
				const size_t p = static_cast<size_t>(off) + static_cast<size_t>(bmpRow) * stride + static_cast<size_t>(lx) * 4;
				if (a != 0) {
					out[p] = 255;
					out[p + 1] = 255;
					out[p + 2] = 255;
					out[p + 3] = 255;
				}
			}
		}
		return out;
	}
}

suite<"io"> occupancyMaskTest = [] {
	test("occupancyFromBmp reads bottom-up alpha") = [] {
		const auto bmp = bmp32(2, 2, { 0, 255, 255, 0 });
		OccupancyMask occ;
		expect(occupancyFromBmp(bmp.data(), bmp.size(), 10, 20, occ));
		expect(eq(occ.tiles, 2u));
		expect(occ.contains(11, 20));
		expect(occ.contains(10, 21));
		expect(!occ.contains(10, 20));
		expect(!occ.contains(11, 21));
	};

	test("occupancyFromPacked round-trips a tiny packed fixture") = [] {
		const auto path = std::filesystem::path(__FILE__).parent_path() / "fixtures" / "occupancy-2x2.bmp.lzma";
		const auto packed = readAll(path);
		OccupancyMask occ;
		expect(occupancyFromPacked(packed.data(), packed.size(), 10, 20, occ));
		expect(eq(occ.width, 3));
		expect(eq(occ.height, 2));
		expect(eq(occ.tiles, 2u));
		expect(occ.contains(10, 20));
		expect(occ.contains(12, 21));
		expect(!occ.contains(11, 20));
	};
};
