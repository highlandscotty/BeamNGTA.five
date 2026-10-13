import random
random.seed(1)
offset = 1234.567
window, v = [], 4.0
def packet_age(now, gt):
    window.append(now - gt)
    if len(window) > 120: window.pop(0)
    return min(0.1, now - gt - min(window))
worst_naive = worst = 0.0
t_read, n = 0.0, 0
for frame in range(2000):
    t_read += 1 / 45 + random.uniform(-0.003, 0.003)
    k = int((t_read - 0.0005) * 60)
    made = k / 60
    age = packet_age(t_read, made - offset)
    true_x = v * t_read
    if frame > 200:
        worst_naive = max(worst_naive, abs(true_x - v * made))
        worst = max(worst, abs(true_x - (v * made + v * age)))
        n += 1
assert worst_naive > 0.05
assert worst < 0.006
print("ok  (error at a run: %.1f cm before, %.1f cm now)" % (worst_naive * 100, worst * 100))
