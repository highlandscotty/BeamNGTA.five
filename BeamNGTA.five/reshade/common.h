#pragma once
#include <stdint.h>
#include <string.h>
#define PIPE_NAME "Local\\GtaBeamFrame3"
#define OUT_MAX_W 1920u
#define OUT_MAX_H 1200u
#define PIPE_MAX_BYTES (OUT_MAX_W * OUT_MAX_H * 4u)
#define PIPE_SLOTS 3
struct PipeSlot {
	volatile uint32_t seq;
	uint32_t width, height;
	uint32_t bgr;
	uint32_t frame;
	uint32_t tick;
	uint32_t pad[2];
};
struct PipeHeader {
	volatile uint32_t latest;
	volatile uint32_t frame;
	volatile uint32_t beamTick;
	uint32_t pad[5];
	PipeSlot slot[PIPE_SLOTS];
};
#define TICK_EVENT "Local\\GtaBeamTick"
#define PIPE_SIZE (sizeof(PipeHeader) + (size_t)PIPE_SLOTS * PIPE_MAX_BYTES)
#define PIPE_PIXELS(hdr, i) ((uint8_t *)((hdr) + 1) + (size_t)(i) * PIPE_MAX_BYTES)

static inline void fit(uint32_t w, uint32_t h, uint32_t *ow, uint32_t *oh) {
	*ow = w; *oh = h;
	if (w <= OUT_MAX_W && h <= OUT_MAX_H) return;
	if ((uint64_t)w * OUT_MAX_H > (uint64_t)h * OUT_MAX_W) { *ow = OUT_MAX_W; *oh = (uint32_t)((uint64_t)h * OUT_MAX_W / w); }
	else { *oh = OUT_MAX_H; *ow = (uint32_t)((uint64_t)w * OUT_MAX_H / h); }
}
static inline uint32_t from10(uint32_t p) {
	return ((p >> 2) & 0xFF) | (((p >> 12) & 0xFF) << 8) | (((p >> 22) & 0xFF) << 16) | ((p >> 30) ? 0xFF000000u : 0u);
}
static inline void put(uint8_t *dst, uint32_t ow, uint32_t oh, const uint8_t *src, uint32_t pitch, uint32_t w, uint32_t h, bool ten) {
	if (!ten && ow == w && oh == h) {
		for (uint32_t y = 0; y < h; y++) memcpy(dst + (size_t)y * w * 4, src + (size_t)y * pitch, (size_t)w * 4);
		return;
	}
	static uint32_t xmap[OUT_MAX_W];
	for (uint32_t x = 0; x < ow; x++) xmap[x] = (uint32_t)((uint64_t)x * w / ow);
	for (uint32_t y = 0; y < oh; y++) {
		const uint32_t *row = (const uint32_t *)(src + (size_t)((uint64_t)y * h / oh) * pitch);
		uint32_t *o = (uint32_t *)(dst + (size_t)y * ow * 4);
		for (uint32_t x = 0; x < ow; x++) { uint32_t p = row[xmap[x]]; o[x] = ten ? from10(p) : p; }
	}
}
