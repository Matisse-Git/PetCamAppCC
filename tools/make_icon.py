"""Draws the PetCam app icon (1024x1024 PNG) with the standard library only.

Usage:  python tools/make_icon.py
Writes: PetCam/Assets.xcassets/AppIcon.appiconset/AppIcon.png
"""
import math
import os
import struct
import zlib

SIZE = 1024
SS = 2  # supersampling per axis for smooth edges

TOP = (255, 159, 67)      # warm orange
BOTTOM = (238, 82, 83)    # coral
WHITE = (255, 255, 255)

# Paw: main pad + four toes, as (cx, cy, rx, ry, angle_degrees) in 0..1 units.
PADS = [
    (0.500, 0.665, 0.190, 0.150, 0),
    (0.270, 0.455, 0.070, 0.092, -25),
    (0.405, 0.335, 0.072, 0.095, -8),
    (0.595, 0.335, 0.072, 0.095, 8),
    (0.730, 0.455, 0.070, 0.092, 25),
]


def inside_paw(x, y):
    for cx, cy, rx, ry, angle in PADS:
        a = math.radians(angle)
        dx, dy = x - cx, y - cy
        u = dx * math.cos(a) + dy * math.sin(a)
        v = -dx * math.sin(a) + dy * math.cos(a)
        if (u / rx) ** 2 + (v / ry) ** 2 <= 1.0:
            return True
    return False


def pixel(px, py):
    hits = 0
    for sy in range(SS):
        for sx in range(SS):
            x = (px + (sx + 0.5) / SS) / SIZE
            y = (py + (sy + 0.5) / SS) / SIZE
            if inside_paw(x, y):
                hits += 1
    t = py / (SIZE - 1)
    bg = tuple(round(TOP[i] + (BOTTOM[i] - TOP[i]) * t) for i in range(3))
    k = hits / (SS * SS)
    return bytes(round(bg[i] + (WHITE[i] - bg[i]) * k) for i in range(3))


def png(width, height, rows):
    def chunk(kind, data):
        body = kind + data
        return struct.pack(">I", len(data)) + body + struct.pack(">I", zlib.crc32(body) & 0xFFFFFFFF)

    raw = b"".join(b"\x00" + row for row in rows)
    return (
        b"\x89PNG\r\n\x1a\n"
        + chunk(b"IHDR", struct.pack(">IIBBBBB", width, height, 8, 2, 0, 0, 0))
        + chunk(b"IDAT", zlib.compress(raw, 9))
        + chunk(b"IEND", b"")
    )


def main():
    rows = []
    for py in range(SIZE):
        rows.append(b"".join(pixel(px, py) for px in range(SIZE)))
    root = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
    out = os.path.join(root, "PetCam", "Assets.xcassets", "AppIcon.appiconset", "AppIcon.png")
    os.makedirs(os.path.dirname(out), exist_ok=True)
    with open(out, "wb") as f:
        f.write(png(SIZE, SIZE, rows))
    print("wrote", out)


if __name__ == "__main__":
    main()
