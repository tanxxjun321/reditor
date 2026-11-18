#!/usr/bin/env python3
"""把 app.png 主体(圆角矩形)抠出,四角透明,输出 1024 master + .iconset 全套尺寸。"""
import os
import sys

# 脚本以 python3 -I 运行(隔离模式),PIL 装在用户 site-packages,显式加入路径
sys.path.insert(0, "/Users/tanjun/Library/Python/3.9/lib/python/site-packages")
from PIL import Image, ImageDraw

SRC, OUTDIR = sys.argv[1], sys.argv[2]

im = Image.open(SRC).convert("RGBA")
w, h = im.size
px = im.load()

# 背景色:取四角平均
corners = [px[2, 2], px[w - 3, 2], px[2, h - 3], px[w - 3, h - 3]]
bg = tuple(sum(c[i] for c in corners) // 4 for i in range(3))
print("bg:", bg)

THR = 60  # 与背景的 RGB 距离阈值;主体为亮青绿,投影很暗,60 可排除投影


def diff(c):
    return abs(c[0] - bg[0]) + abs(c[1] - bg[1]) + abs(c[2] - bg[2])


STEP = 2
col_cnt = [sum(1 for y in range(0, h, STEP) if diff(px[x, y]) > THR) for x in range(w)]
row_cnt = [sum(1 for x in range(0, w, STEP) if diff(px[x, y]) > THR) for y in range(h)]

# 主体边界:该行/列过半像素与背景不同
x0 = next(x for x in range(w) if col_cnt[x] > (h / STEP) * 0.5)
x1 = next(x for x in range(w - 1, -1, -1) if col_cnt[x] > (h / STEP) * 0.5)
y0 = next(y for y in range(h) if row_cnt[y] > (w / STEP) * 0.5)
y1 = next(y for y in range(h - 1, -1, -1) if row_cnt[y] > (w / STEP) * 0.5)
print(f"bounds: x {x0}..{x1}  y {y0}..{y1}  ({x1 - x0 + 1}x{y1 - y0 + 1})")

# 圆角半径:顶边平直段起点距 x0 的距离 ≈ r(多行取中位数抗锯齿)
radii = []
for y in (y0 + 1, y0 + 2, y0 + 3, y0 + 4, y1 - 2, y1 - 3, y1 - 4):
    xs = [x for x in range(x0, x1 + 1) if diff(px[x, y]) > THR]
    if xs:
        radii.append(min(xs) - x0)
radii.sort()
r = radii[len(radii) // 2] + 30
print("corner radius:", r)

# 4x 超采样圆角矩形蒙版,降采样得到平滑 alpha
S = 4
mask = Image.new("L", (w * S, h * S), 0)
d = ImageDraw.Draw(mask)
d.rounded_rectangle([x0 * S, y0 * S, (x1 + 1) * S - 1, (y1 + 1) * S - 1],
                    radius=r * S, fill=255)
mask = mask.resize((w, h), Image.LANCZOS)

im.putalpha(mask)
master = os.path.join(OUTDIR, "AppIcon_1024.png")
im.save(master)

# iconset
iconset = os.path.join(OUTDIR, "AppIcon.iconset")
os.makedirs(iconset, exist_ok=True)
for name, size in [
    ("icon_16x16.png", 16), ("icon_16x16@2x.png", 32),
    ("icon_32x32.png", 32), ("icon_32x32@2x.png", 64),
    ("icon_128x128.png", 128), ("icon_128x128@2x.png", 256),
    ("icon_256x256.png", 256), ("icon_256x256@2x.png", 512),
    ("icon_512x512.png", 512), ("icon_512x512@2x.png", 1024),
]:
    im.resize((size, size), Image.LANCZOS).save(os.path.join(iconset, name))
print("done:", master)
