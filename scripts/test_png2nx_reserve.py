"""Index 255 must stay free for the Layer 2 transparent colour, and a
source containing that colour must be reported rather than silently
altered by the interpreter's palette dodge."""
import sys, io
from PIL import Image
sys.path.insert(0, __import__("os").path.dirname(__file__))
import png2nx

def _busy_image():
    """320x8 with far more than 255 distinct colours."""
    im = Image.new("RGB", (320, 8))
    px = im.load()
    for y in range(8):
        for x in range(320):
            n = y * 320 + x
            px[x, y] = (n % 256, (n // 7) % 256, (n // 13) % 256)
    return im

def test_index_255_never_used():
    q = png2nx.quantize(_busy_image())
    assert max(q.tobytes()) <= 254, (
        "index 255 is reserved for the Layer 2 transparent colour; "
        f"quantize produced index {max(q.tobytes())}")

def test_palette_still_full_length():
    q = png2nx.quantize(_busy_image())
    assert len(q.getpalette()) == 768, "palette must stay padded to 256 entries"

if __name__ == "__main__":
    test_index_255_never_used()
    test_palette_still_full_length()
    print("png2nx reserve checks: PASS")
