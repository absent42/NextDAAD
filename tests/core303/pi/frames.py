"""PC-side frame generator for the P2 bench. Not in BUNDLE.txt: never shipped to the Pi.
No video clip is tracked in the repo, so frames are a seeded synthetic sequence.
"""
from pathlib import Path

import numpy as np
from PIL import Image, ImageDraw

W, H = 256, 192
SEED = 303
QUALITY = 75
DEFAULT_DIR = Path(__file__).resolve().parents[3] / "build" / "core303" / "frames"


def to_rrrgggbb(rgb):
    """(H, W, 3) uint8 -> (H, W) uint8: R high 3 bits, G high 3 bits, B high 2 bits."""
    r, g, b = rgb[..., 0], rgb[..., 1], rgb[..., 2]
    return (r & 0xE0) | ((g & 0xE0) >> 3) | (b >> 6)


def _frame(t, rng):
    x = np.arange(W, dtype=np.int32)[None, :]
    y = np.arange(H, dtype=np.int32)[:, None]
    rgb = np.empty((H, W, 3), dtype=np.uint8)
    rgb[..., 0] = (x + 3 * t) & 255
    rgb[..., 1] = (y * 255 // (H - 1) + 2 * t) & 255
    rgb[..., 2] = ((x + y) // 2 + 5 * t) & 255
    bx, by = int(rng.integers(0, W - 32)), int(rng.integers(0, H - 32))
    rgb[by:by + 32, bx:bx + 32] = rng.integers(0, 256, 3, dtype=np.uint8)
    im = Image.fromarray(rgb, "RGB")
    d = ImageDraw.Draw(im)
    d.text((8 + 2 * t % 120, 8), "NEXTDAAD %03d" % t, fill=(255, 255, 255))
    d.text((8, H - 20), "frame %d of the P2 bench" % t, fill=(255, 255, 0))
    return im


def make(out_dir=DEFAULT_DIR, n=120):
    out = Path(out_dir)
    out.mkdir(parents=True, exist_ok=True)
    rng = np.random.default_rng(SEED)
    for i in range(n):
        im = _frame(i, rng)
        stem = out / ("F%03d" % i)
        im.save(str(stem) + ".png")
        im.save(str(stem) + ".jpg", quality=QUALITY)
        Path(str(stem) + ".raw").write_bytes(to_rrrgggbb(np.asarray(im)).tobytes())
    (out / "SOURCE.txt").write_text("synthetic seed=%d\n" % SEED, encoding="ascii")
    return out


if __name__ == "__main__":
    print(make())
