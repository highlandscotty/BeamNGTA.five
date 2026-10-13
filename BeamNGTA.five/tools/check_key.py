import math
near, h, pitch, tanh, asp = 0.15, 1.5, math.radians(-20), math.tan(math.radians(30)), 16 / 9
def water(x, y):
    up = (1 - 2 * y) * tanh * math.cos(pitch) + math.sin(pitch)
    return 0.0 if up >= 0 else near * -up / h
for y in [0.1, 0.3, 0.5, 0.7, 0.9, 0.99]:
    w = min(water(x, y) for x in [0.02, 0.2, 0.4, 0.6, 0.8, 0.98])
    for x in [0.1, 0.5, 0.9]:
        assert abs(water(x, y) - w) < 1e-12 and not water(x, y) > w * 1.08
    if w > 0:
        n = w / (1 - 0.10)
        assert n > w * 1.08 and abs((1 - w / n) * h - 0.15) < 1e-9
import os, re
fx = open(os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "reshade", "GtaKey.fx")).read()
body = fx[fx.index("float3 Sdr("):fx.index("float Near(")]
m2, c1, c2, c3, m1 = [float(v) for v in re.findall(r"[\d.]+", body[body.index("pow(saturate(c)"):body.index("/ HdrWhite")]) if "." in v and v not in ("1.0", "10000.0", "0.0")]
rows = [[float(v) for v in r.split(",")] for r in re.findall(r"float3\((-?[\d.]+, -?[\d.]+, -?[\d.]+)\)", body)]
def pq(nits):
    y = (nits / 10000) ** m1
    return ((c1 + c2 * y) / (1 + c3 * y)) ** m2
def sdr(c, white=203.0):
    p = [min(max(v, 0), 1) ** (1 / m2) for v in c]
    l = [10000 * (max(v - c1, 0) / (c2 - c3 * v)) ** (1 / m1) / white for v in p]
    l = [sum(a * b for a, b in zip(r, l)) for r in rows]
    return [min(max(v, 0), 1) ** (1 / 2.2) for v in l]
assert len(rows) == 3 and all(abs(sum(r) - 1) < 2e-4 for r in rows)
assert all(abs(v - 1) < 1e-3 for v in sdr([pq(203)] * 3))
assert all(abs(v - (100 / 203) ** (1 / 2.2)) < 1e-3 for v in sdr([pq(100)] * 3))
assert sdr([0, 0, 0]) == [0, 0, 0] and sdr([pq(1000)] * 3) == [1, 1, 1]
print("ok")
