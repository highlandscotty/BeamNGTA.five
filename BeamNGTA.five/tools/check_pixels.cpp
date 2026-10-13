#include <assert.h>
#include <stdio.h>
#include <vector>
#include "../reshade/common.h"

static uint32_t pack10(uint32_t r, uint32_t g, uint32_t b, uint32_t a) { return r | (g << 10) | (b << 20) | (a << 30); }
static uint32_t to10(uint32_t k) { return (k * 1023 * 2 + 255) / (255 * 2); }

int main()
{
	uint32_t ow, oh;
	fit(1920, 1080, &ow, &oh); assert(ow == 1920 && oh == 1080);
	fit(1920, 1200, &ow, &oh); assert(ow == 1920 && oh == 1200);
	fit(2560, 1440, &ow, &oh); assert(ow == 1920 && oh == 1080);
	fit(3440, 1440, &ow, &oh); assert(ow == 1920 && oh == 803);
	fit(3840, 2160, &ow, &oh); assert(ow == 1920 && oh == 1080);
	fit(1600, 1600, &ow, &oh); assert(ow == 1200 && oh == 1200);
	fit(1080, 1920, &ow, &oh); assert(ow == 675 && oh == 1200);

	for (uint32_t k = 0; k < 256; k++) {
		assert(from10(pack10(to10(k), to10(255 - k), to10(k ^ 1), 3)) == (k | ((255 - k) << 8) | ((k ^ 1) << 16) | 0xFF000000u));
		assert(from10(pack10(to10(k), 0, 0, 0)) == k);
	}

	const uint32_t w = 5, h = 3, pitch = 32;
	std::vector<uint8_t> src(pitch * h, 0xEE), dst(w * h * 4, 0);
	for (uint32_t y = 0; y < h; y++) for (uint32_t x = 0; x < w; x++) ((uint32_t *)(src.data() + y * pitch))[x] = 0x01000000u * (y + 1) + x;
	put(dst.data(), w, h, src.data(), pitch, w, h, false);
	for (uint32_t y = 0; y < h; y++) for (uint32_t x = 0; x < w; x++) assert(((uint32_t *)dst.data())[y * w + x] == 0x01000000u * (y + 1) + x);

	const uint32_t W = 2560, H = 1440, P = 2560 * 4 + 256;
	std::vector<uint8_t> big((size_t)P * H), out((size_t)1920 * 1080 * 4);
	for (uint32_t y = 0; y < H; y++) for (uint32_t x = 0; x < W; x++) ((uint32_t *)(big.data() + (size_t)y * P))[x] = pack10(to10(x & 255), to10(y & 255), to10((x + y) & 255), (x ^ y) & 1 ? 3 : 0);
	fit(W, H, &ow, &oh);
	put(out.data(), ow, oh, big.data(), P, W, H, true);
	for (uint32_t y = 0; y < oh; y += 7) for (uint32_t x = 0; x < ow; x += 5) {
		uint32_t sx = x * W / ow, sy = y * H / oh;
		uint32_t want = (sx & 255) | ((sy & 255) << 8) | (((sx + sy) & 255) << 16) | ((sx ^ sy) & 1 ? 0xFF000000u : 0u);
		assert(((uint32_t *)out.data())[(size_t)y * ow + x] == want);
	}

	puts("ok");
	return 0;
}
