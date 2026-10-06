"""Where does the red in the iOS saved copy come from? Live iPhone Vision matte, pm02, dark #1F2328 replacement."""
import struct, numpy as np
def bmp(p):
    d = open(p, 'rb').read(); off, = struct.unpack_from('<I', d, 10); w, h = struct.unpack_from('<ii', d, 18); bpp, = struct.unpack_from('<H', d, 28)
    st = bpp // 8; row = (w * st + 3) & ~3
    a = np.frombuffer(d, np.uint8, offset=off, count=row * abs(h)).reshape(abs(h), row)[:, :w * st].reshape(abs(h), w, st)
    a = a[::-1] if h > 0 else a
    return a[:, :, 2::-1].astype(float) if st >= 3 else a[:, :, 0].astype(float)
I, C, M = bmp('orig.bmp'), bmp('saved.bmp'), bmp('matte.bmp')
if M.ndim == 3: M = M[..., 0]
M = M / 255; H, W = M.shape
R = np.array([0x1F, 0x23, 0x28], float)
red = lambda x: x[..., 0] - (x[..., 1] + x[..., 2]) / 2
head = np.zeros_like(M, bool); head[:int(H * .45)] = True
# Visible red in the result: clearly red, and not in the original's interior skin/lips (only near the outline: within
# the outline band, or matte==1 but next to matte<0.5 within 40 px).
import numpy.lib.stride_tricks as st_
k = 40
low = (M < 0.5).astype(np.uint8)
# distance-to-background proxy: max-filter of `low` over a k x k window (separable)
def maxf(a, k):
    p = np.pad(a, ((k, k), (0, 0))); a = np.max(np.stack([p[i:i + a.shape[0]] for i in range(2 * k + 1)]), 0)
    p = np.pad(a, ((0, 0), (k, k))); return np.max(np.stack([p[:, i:i + a.shape[1]] for i in range(2 * k + 1)]), 0)
nearbg = maxf(low[::2, ::2], k // 2).repeat(2, 0).repeat(2, 1)[:H, :W].astype(bool)
redC = head & nearbg & (red(C) > 25)
print(f'red pixels in the result near the outline (head region): {redC.sum()}')
bins = [('matte >= 0.98 (subject)', M >= 0.98), ('0.02 < matte < 0.98 (soft edge)', (M > 0.02) & (M < 0.98)), ('matte <= 0.02 (background)', M <= 0.02)]
for name, b in bins:
    m = redC & b
    if not m.sum(): print(f'  {name}: 0'); continue
    dI = np.abs(C[m] - I[m]).mean()
    print(f'  {name}: {m.sum():6d} ({m.sum() / redC.sum():.0%})  original there: rgb {I[m].mean(0).round(0)}, red excess {red(I[m]).mean():.0f}; result rgb {C[m].mean(0).round(0)}; |result - original| {dI:.1f}')
# The wall: background pixels of the original near the head
wall = head & (M <= 0.02) & nearbg
print(f'wall (original, matte<=0.02 near the outline): rgb {I[wall].mean(0).round(0)}')
np.save('redC.npy', redC)
