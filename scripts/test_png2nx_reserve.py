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

def test_warns_on_near_magenta_not_just_canonical():
    """(230, 8, 200) is NOT the canonical (224, 0, 192) triple, but it
    packs to the same RGB332 byte $E3 that hardware compares against:
        r=230 -> r&0xE0       = 0xE0
        g=8   -> (g>>3)&0x1C  = 0x01
        b=200 -> b>>6         = 0x03
        byte0                 = 0xE0|0x01|0x03 = 0xE3
    An exact-tuple check against only (224, 0, 192) would miss this
    and stay silent while hardware still punches a hole. Single-colour
    image so PIL's adaptive palette preserves the triple exactly (no
    clustering to distort it) - confirmed separately that PIL does not
    perturb a single-colour source's palette entry."""
    im = Image.new("RGB", (16, 16), (230, 8, 200))
    old_stdout = sys.stdout
    sys.stdout = captured = io.StringIO()
    try:
        png2nx.quantize(im, name="near-magenta-fixture")
    finally:
        sys.stdout = old_stdout
    out = captured.getvalue()
    assert "WARNING" in out and "near-magenta-fixture" in out, (
        "quantize did not warn on (230, 8, 200), which packs to the "
        "reserved RGB332 byte $E3 even though it is not the canonical "
        f"(224, 0, 192) triple. Captured stdout: {out!r}")

if __name__ == "__main__":
    test_index_255_never_used()
    test_palette_still_full_length()
    test_warns_on_near_magenta_not_just_canonical()
    print("png2nx reserve checks: PASS")
