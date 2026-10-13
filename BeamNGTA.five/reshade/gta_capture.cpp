#define NOMINMAX
#include <windows.h>
#include <reshade.hpp>
#include <string.h>
#include <stdio.h>
#include "common.h"
using namespace reshade::api;
extern "C" { int _fltused = 0; }
static void L(const char *m) { reshade::log::message(reshade::log::level::info, m); }

static HANDLE g_map; static PipeHeader *g_pipe;
static void keepFocus(HWND h);
static resource g_stage[3]; static bool g_pend[3]; static uint32_t g_tag[3]; static uint64_t g_mark[3]; static int g_si, g_cur = -1; static uint32_t g_sw, g_sh; static format g_sf;
static uint32_t g_tick, g_relTick;
static uint32_t g_sameFrame, g_late;
static device *g_dev; static void *g_ctx; static fence g_fence; static uint64_t g_fv;
static bool g_on;
struct MappedSub { void *pData; UINT RowPitch; UINT DepthPitch; };
typedef HRESULT (__stdcall *MapFn)(void *self, void *res, UINT sub, UINT mapType, UINT flags, MappedSub *out);
typedef void (__stdcall *UnmapFn)(void *self, void *res, UINT sub);

static bool grab(int j, const uint8_t **p, uint32_t *pitch)
{
	if (g_ctx) {
		MappedSub ms = {};
		if (FAILED(((MapFn)(*(void ***)g_ctx)[14])(g_ctx, (void *)g_stage[j].handle, 0, 1, 0x100000, &ms)) || !ms.pData) return false;
		*p = (const uint8_t *)ms.pData; *pitch = ms.RowPitch;
		return true;
	}
	if (g_dev->get_completed_fence_value(g_fence) < g_mark[j]) return false;
	subresource_data sd = {};
	if (!g_dev->map_texture_region(g_stage[j], 0, nullptr, map_access::read_only, &sd) || !sd.data) return false;
	*p = (const uint8_t *)sd.data; *pitch = sd.row_pitch;
	return true;
}
static void release(int j)
{
	if (g_ctx) ((UnmapFn)(*(void ***)g_ctx)[15])(g_ctx, (void *)g_stage[j].handle, 0);
	else g_dev->unmap_texture_region(g_stage[j], 0);
}

static bool publish()
{
	if (!g_dev || g_cur < 0) return true;
	for (int a = 0; a <= 2; a++) {
		int j = (g_cur + 3 - a) % 3;
		if (!g_pend[j]) continue;
		const uint8_t *src; uint32_t pitch;
		if (!grab(j, &src, &pitch)) continue;
		static uint32_t counter = 0;
		uint32_t ow, oh; fit(g_sw, g_sh, &ow, &oh);
		uint32_t si = (g_pipe->latest + 1) % PIPE_SLOTS;
		PipeSlot *sl = &g_pipe->slot[si];
		sl->seq++;
		put(PIPE_PIXELS(g_pipe, si), ow, oh, src, pitch, g_sw, g_sh, g_sf == format::r10g10b10a2_unorm);
		sl->width = ow; sl->height = oh;
		sl->bgr = (g_sf == format::b8g8r8a8_unorm || g_sf == format::b8g8r8x8_unorm) ? 1 : 0;
		sl->tick = g_tag[j];
		sl->frame = ++counter;
		sl->seq++;
		g_pipe->frame = counter; g_pipe->latest = si;
		release(j);
		for (int o = a; o <= 2; o++) g_pend[(g_cur + 3 - o) % 3] = false;
		if (a == 0) g_sameFrame++; else g_late++;
		break;
	}
	return !g_pend[g_cur];
}

static bool usable(format f)
{
	return f == format::r8g8b8a8_unorm || f == format::r8g8b8x8_unorm || f == format::b8g8r8a8_unorm || f == format::b8g8r8x8_unorm || f == format::r10g10b10a2_unorm;
}

static void capture(effect_runtime *rt, command_list *cmd, resource_view rtv, resource_view)
{
	if (!g_pipe) return;
	static bool first = true; if (first) { first = false; L("gta_capture: first finish_effects"); }
	++g_tick;
	if (g_tick < 600 || !g_on) return;
	keepFocus((HWND)rt->get_hwnd());
	static DWORD t0 = 0; static uint32_t n0 = 0;
	if (t0 == 0 || g_tick - n0 >= 300) {
		DWORD t1 = GetTickCount();
		if (t0) { char m[128]; _snprintf(m, sizeof m, "gta_capture: %.1f fps, pictures out within their own frame %u, later %u", (double)(g_tick - n0) * 1000.0 / (double)(t1 - t0 ? t1 - t0 : 1), g_sameFrame, g_late); L(m); }
		t0 = t1; n0 = g_tick; g_sameFrame = g_late = 0;
	}
	device *dev = rt->get_device();
	command_queue *q = rt->get_command_queue();
	resource bb = dev->get_resource_from_view(rtv);
	resource_desc d = dev->get_resource_desc(bb);
	uint32_t w = d.texture.width, h = d.texture.height;
	format f = format_to_default_typed(d.texture.format, 0);
	if (!usable(f)) {
		static format said = format::unknown;
		if (said != f) { said = f; char m[96]; _snprintf(m, sizeof m, "gta_capture: cannot read picture format %u", (unsigned)f); L(m); }
		return;
	}
	if (dev != g_dev) {
		for (int i = 0; i < 3; i++) { g_stage[i].handle = 0; g_pend[i] = false; }
		g_fence.handle = 0; g_cur = -1;
		g_dev = dev;
		g_ctx = dev->get_api() == device_api::d3d11 ? (void *)q->get_native() : nullptr;
	}
	if (!g_ctx && g_fence.handle == 0 && !dev->create_fence(0, fence_flags::none, &g_fence)) {
		g_fence.handle = 0;
		static bool said = false; if (!said) { said = true; L("gta_capture: create fence FAILED"); }
		return;
	}
	if (g_stage[0].handle == 0 || g_sw != w || g_sh != h || g_sf != f) {
		if (g_stage[0].handle) q->wait_idle();
		for (int i = 0; i < 3; i++) { if (g_stage[i].handle) dev->destroy_resource(g_stage[i]); g_stage[i].handle = 0; g_pend[i] = false; }
		char m[128]; _snprintf(m, sizeof m, "gta_capture: reading %ux%u, format %u, %s", w, h, (unsigned)f, g_ctx ? "Direct3D 11" : "fence"); L(m);
		g_cur = -1;
		for (int i = 0; i < 3; i++)
			if (!dev->create_resource(resource_desc(w, h, 1, 1, f, 1, memory_heap::gpu_to_cpu, resource_usage::copy_dest), nullptr, resource_usage::copy_dest, &g_stage[i])) { g_stage[i].handle = 0; g_stage[0].handle = 0; L("gta_capture: create staging FAILED"); return; }
		g_sw = w; g_sh = h; g_sf = f;
	}
	cmd->barrier(bb, resource_usage::render_target, resource_usage::copy_source);
	cmd->copy_texture_region(bb, 0, nullptr, g_stage[g_si], 0, nullptr);
	cmd->barrier(bb, resource_usage::copy_source, resource_usage::render_target);
	g_pend[g_si] = true; g_tag[g_si] = g_relTick; g_cur = g_si;
	if (g_ctx) q->flush_immediate_command_list();
	else { q->signal(g_fence, ++g_fv); g_mark[g_si] = g_fv; }
	g_si = (g_si + 1) % 3;
	publish();
}

static WNDPROC g_orig; static HWND g_hw;
static LRESULT CALLBACK focusProc(HWND h, UINT m, WPARAM w, LPARAM l) {
	if (g_on && ((m == WM_ACTIVATEAPP && !w) || (m == WM_ACTIVATE && LOWORD(w) == WA_INACTIVE) || m == WM_KILLFOCUS)) return 0;
	return CallWindowProcW(g_orig, h, m, w, l);
}
static void keepFocus(HWND h) {
	if (g_hw || !h) return;
	g_hw = h;
	char b[8]; size_t n = 7;
	if (reshade::get_config_value(nullptr, "GTABRIDGE", "KeepFocus", b, &n) && b[0] == '0') { L("gta_capture: KeepFocus=0"); return; }
	g_orig = (WNDPROC)SetWindowLongPtrW(h, GWLP_WNDPROC, (LONG_PTR)focusProc);
	if (!g_orig) { L("gta_capture: could not hook the window"); return; }
	PostMessageW(h, WM_ACTIVATEAPP, 1, 0); PostMessageW(h, WM_ACTIVATE, WA_ACTIVE, 0); PostMessageW(h, WM_SETFOCUS, 0, 0);
	L("gta_capture: focus-loss messages blocked (full frame rate in the background)");
}

static void focus(bool on) {
	if (!g_orig) return;
	if (on) { PostMessageW(g_hw, WM_ACTIVATEAPP, 1, 0); PostMessageW(g_hw, WM_ACTIVATE, WA_ACTIVE, 0); PostMessageW(g_hw, WM_SETFOCUS, 0, 0); }
	else if (GetForegroundWindow() != g_hw) { PostMessageW(g_hw, WM_KILLFOCUS, 0, 0); PostMessageW(g_hw, WM_ACTIVATE, WA_INACTIVE, 0); PostMessageW(g_hw, WM_ACTIVATEAPP, 0, 0); }
}

static void boost(bool on) {
	static DWORD was;
	if (on) { was = GetPriorityClass(GetCurrentProcess()); SetPriorityClass(GetCurrentProcess(), 0x80); }
	else if (was) SetPriorityClass(GetCurrentProcess(), was);
	HMODULE g = LoadLibraryA("gdi32.dll"); if (!g) return;
	typedef long (__stdcall *Fn)(HANDLE, int);
	Fn f = (Fn)GetProcAddress(g, "D3DKMTSetProcessSchedulingPriorityClass"); if (!f) return;
	for (int cls = on ? 4 : 2; cls >= (on ? 3 : 2); cls--) {
		long st = f(GetCurrentProcess(), cls);
		char m[96]; _snprintf(m, sizeof m, "gta_capture: GPU priority class %d -> status 0x%08lX", cls, (unsigned long)st); L(m);
		if (st >= 0) break;
	}
}

static double nowSec() {
	static double inv = 0; LARGE_INTEGER c; QueryPerformanceCounter(&c);
	if (inv == 0) { LARGE_INTEGER q; QueryPerformanceFrequency(&q); inv = 1.0 / (double)q.QuadPart; }
	return (double)c.QuadPart * inv;
}
static void pace() {
	static int cap = -1, lock = 1; static HANDLE tmr, ev; static double next, lastRel; static uint32_t seen, waits, timeouts;
	if (cap < 0) {
		cap = 60; char b[16]; size_t n = 15;
		if (reshade::get_config_value(nullptr, "GTABRIDGE", "FpsCap", b, &n)) { int v = 0; for (const char *c = b; *c >= '0' && *c <= '9'; c++) v = v * 10 + (*c - '0'); cap = v; }
		n = 15; if (reshade::get_config_value(nullptr, "GTABRIDGE", "FrameLock", b, &n) && b[0] == '0') lock = 0;
		tmr = CreateWaitableTimerExW(nullptr, nullptr, 0x2 , 0x1F0003);
		ev = CreateEventA(nullptr, FALSE, FALSE, TICK_EVENT);
		char m[96]; _snprintf(m, sizeof m, "gta_capture: FpsCap=%d FrameLock=%d event=%d timer=%d", cap, lock, ev ? 1 : 0, tmr ? 1 : 0); L(m);
	}
	double t0 = nowSec();
	if (lock && ev && tmr) {
		double minGap = cap > 0 ? 0.9 / cap : 0.0;
		bool out = false;
		for (;;) {
			if (!out) out = publish();
			double now = nowSec();
			if (g_pipe->beamTick != seen && now - lastRel >= minGap) break;
			if (now - t0 > 0.05) { timeouts++; break; }
			LARGE_INTEGER due; due.QuadPart = -5000;
			SetWaitableTimer(tmr, &due, 0, nullptr, nullptr, FALSE);
			HANDLE hs[2] = { ev, tmr };
			WaitForMultipleObjects(2, hs, FALSE, 5);
		}
		seen = g_relTick = g_pipe->beamTick;
		lastRel = nowSec();
		if (++waits % 600 == 0) { char m[96]; _snprintf(m, sizeof m, "gta_capture: in step with BeamNG, %u of the last 600 frames went without its signal", timeouts); L(m); timeouts = 0; }
		return;
	}
	g_relTick = 0;
	if (cap <= 0) return;
	double now = t0;
	if (next == 0) next = now;
	next += 1.0 / cap;
	if (next < now) next = now;
	double rem = next - now;
	if (rem > 0.0015) {
		if (tmr) { LARGE_INTEGER due; due.QuadPart = -(LONGLONG)((rem - 0.0015) * 1e7); SetWaitableTimer(tmr, &due, 0, nullptr, nullptr, FALSE); WaitForSingleObject(tmr, 50); }
		else Sleep((DWORD)((rem - 0.002) * 1000.0));
	}
	while (nowSec() < next) YieldProcessor();
}
static void on_finish_effects(effect_runtime *rt, command_list *cmd, resource_view rtv, resource_view srgb)
{
	capture(rt, cmd, rtv, srgb);
	if (g_on && g_tick >= 600 && g_pipe) pace();
}

static void key(effect_runtime *rt, bool on)
{
	effect_technique t = rt->find_technique("GtaKey.fx", "GtaKey");
	static int missed;
	if (t == 0) { if (on && ++missed == 20) L("gta_capture: GtaKey.fx is not loaded: his picture cannot be cut out"); return; }
	missed = 0;
	if (rt->get_technique_state(t) != on) rt->set_technique_state(t, on);
	if (!on) return;
	static effect_technique list[1024]; size_t n = 0; bool last = false;
	rt->enumerate_techniques(nullptr, [&](effect_runtime *, effect_technique x) { last = x == t; if (x != t && n < 1023) list[n++] = x; });
	if (last) return;
	list[n++] = t;
	rt->reorder_techniques(n, list);
}

static void on_present(effect_runtime *rt)
{
	if (!g_pipe) return;
	static uint32_t last, n; static double seen;
	double now = nowSec();
	if (g_pipe->beamTick != last) { last = g_pipe->beamTick; seen = now; }
	bool on = seen != 0 && now - seen < 2.0;
	if (on != g_on || n++ % 30 == 0) key(rt, on);
	if (on == g_on) return;
	g_on = on;
	L(on ? "gta_capture: BeamNG is running: capturing" : "gta_capture: BeamNG is not running: standing by");
	boost(on);
	focus(on);
}

extern "C" __declspec(dllexport) const char *NAME = "GTA frame capture";
extern "C" __declspec(dllexport) const char *DESCRIPTION = "Publishes the keyed GTA frame to shared memory for the BeamNG overlay.";

BOOL APIENTRY DllMain(HMODULE h, DWORD reason, LPVOID)
{
	if (reason == DLL_PROCESS_ATTACH) {
		if (!reshade::register_addon(h)) return FALSE;
		g_map = CreateFileMappingA(INVALID_HANDLE_VALUE, nullptr, PAGE_READWRITE, 0, (DWORD)PIPE_SIZE, PIPE_NAME);
		if (g_map) g_pipe = (PipeHeader *)MapViewOfFile(g_map, FILE_MAP_ALL_ACCESS, 0, 0, PIPE_SIZE);
		L(g_pipe ? "gta_capture: pipe mapped" : "gta_capture: PIPE MAP FAILED");
		reshade::register_event<reshade::addon_event::reshade_finish_effects>(on_finish_effects);
		reshade::register_event<reshade::addon_event::reshade_present>(on_present);
	} else if (reason == DLL_PROCESS_DETACH) {
		if (g_orig && (WNDPROC)GetWindowLongPtrW(g_hw, GWLP_WNDPROC) == focusProc) SetWindowLongPtrW(g_hw, GWLP_WNDPROC, (LONG_PTR)g_orig);
		if (g_pipe) UnmapViewOfFile(g_pipe);
		if (g_map) CloseHandle(g_map);
		reshade::unregister_addon(h);
	}
	return TRUE;
}
