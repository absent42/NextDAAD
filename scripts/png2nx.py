#!/usr/bin/env python3
"""
scripts/png2nx.py - converts a PNG image to the raw NX2/NXI format the
NextDAAD interpreter reads directly (location pictures, title screens).

Usage:
  python scripts\\png2nx.py SRC.png OUT.NX2 [--crop-height N]
  python scripts\\png2nx.py SRC.png OUT.NXI [--crop-height N]

Pipeline (recreated recipe - the original tool was lost in the 2026-07-20
tools/ deletion incident; this rebuilds it from the project's persisted
recipe plus the working reference quantizer in authoring-kit/lib/videnc.py):
  1. Load the source PNG as RGB.
  2. Optionally crop to the top N rows (--crop-height), for sources that
     are letterboxed or include padding below the picture area.
  3. Quantize to an 8-bit paletted image: PIL ADAPTIVE 256-colour
     palette, dither NONE (matches authoring-kit/lib/videnc.py's default and the
     prior one-shot converters this recipe was re-derived from).
  4. Save the paletted image as a temporary 8-bit PNG - gfx2next requires
     an already-paletted source, it rejects truecolour input.
  5. Run tools\\gfx2next\\gfx2next.exe -bitmap -pal-embed on it. -bitmap
     selects Next bitmap mode; -pal-embed prepends the raw 512-byte
     palette to the raw pixel data instead of writing it to a separate
     .nxp file. gfx2next's own palette encoding (2 bytes/entry, RRRGGGBB
     + expanded 9th blue bit) is the authority for this format - it is
     not reproduced here, just passed through.
  6. The result is copied to OUT as-is: 512-byte palette followed by
     width*height index bytes, no header.

Width 320 is the NX2 full-bleed shape (320x256 title/location art).
Width 256 is the NXI paper-area shape (256-wide, used when the location
text area is not overdrawn by the picture). The NextDAAD engine derives
the image height from the file size (bytes-512)/width - there is no
height field, so the output must be exactly 512 + width*height bytes.

Requires: Python 3, Pillow (pip install Pillow). gfx2next.exe is read
from tools\\gfx2next\\ (override with --gfx2next).
"""

import argparse
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

try:
    from PIL import Image
except ImportError:
    print("error: Pillow is required (pip install Pillow)", file=sys.stderr)
    sys.exit(1)

ROOT = Path(__file__).resolve().parent.parent
DEFAULT_GFX2NEXT = ROOT / "tools" / "gfx2next" / "gfx2next.exe"


# Palette index 255 is reserved for the Layer 2 transparent colour
# (L2_TRANSP_INDEX in src/nextdaad.inc). The interpreter stamps that
# entry on every picture load, so any PIXEL using it would be punched
# into a hole. Quantizing to 255 colours keeps art in 0-254 and makes
# the collision impossible rather than merely unlikely.
RESERVED_INDEX = 255
ART_COLOURS = RESERVED_INDEX          # 255 usable colours: 0..254

# 24-bit form of L2_TRANSP_COLOUR ($E3 = RGB332 7,0,3) as a paint
# program shows it - used only in the warning TEXT, since authors
# think in paint-program values. The canonical (224, 0, 192) triple is
# not the only collision: see _packs_to_transparent below.
TRANSPARENT_RGB = (224, 0, 192)

# Packed RGB332 byte gfx2next/the interpreter compare against (NR $14
# hardware compare, L2_TRANSP_COLOUR in src/nextdaad.inc). FOUR FILES
# carry these values and must agree - src/nextdaad.inc is canonical:
#   src/nextdaad.inc          L2_TRANSP_COLOUR / L2_TRANSP_INDEX
#   scripts/png2nx.py         L2_TRANSPARENT_BYTE0 / RESERVED_INDEX (here)
#   authoring-kit/lib/nxv2enc.py    L2_TRANSPARENT_BYTE0
#   authoring-kit/lib/palcheck.ps1  $TRANSP / $RESERVED
# If either value moves, all four move. tests/build-tests.ps1 parses all
# four and fails if they disagree.
L2_TRANSPARENT_BYTE0 = 0xE3


def _packs_to_transparent(r, g, b):
    """True when this 24-bit colour packs to the reserved RGB332 value.
    Hardware compares the PACKED byte, not the 24-bit triple, so a whole
    region of near-magenta collides - not just the canonical
    (224, 0, 192). Packing must match nxv2enc.build_palette_block and
    the interpreter's own l2_palette_load dodge."""
    return ((r & 0xE0) | ((g >> 3) & 0x1C) | (b >> 6)) == L2_TRANSPARENT_BYTE0


def quantize(im, name="image"):
    """RGB -> 8-bit paletted image: PIL ADAPTIVE palette, dither NONE.

    Uses 255 colours, not 256, so index 255 stays free for the Layer 2
    transparent entry. Palette is still padded to the full 256 entries
    (768 bytes) so gfx2next always sees a complete palette."""
    idx_img = im.convert("P", palette=Image.Palette.ADAPTIVE,
                          colors=ART_COLOURS, dither=Image.Dither.NONE)
    pal = idx_img.getpalette() or []
    pal = pal + [0] * (768 - len(pal))
    idx_img.putpalette(pal)

    # Report, do not silently alter: the interpreter's palette dodge
    # would shift a colliding entry one step of the blue field without
    # telling the author anything. Test against the PACKED byte, not
    # the 24-bit triple - PIL's adaptive clustering can land a
    # centroid anywhere in the region that packs to $E3, not just on
    # the canonical (224, 0, 192).
    for i in range(0, min(len(pal), ART_COLOURS * 3), 3):
        r, g, b = pal[i:i + 3]
        if _packs_to_transparent(r, g, b):
            print("WARNING: %s uses the reserved transparency colour "
                  "#E000C0 (or a near-magenta packing to the same "
                  "RGB332 byte) at palette index %d - those pixels "
                  "would show through to the text layer. Change the "
                  "colour slightly." % (name, i // 3))
    return idx_img


def run_gfx2next(gfx2next, work_dir, src_png, dst_name):
    """Run gfx2next -bitmap -pal-embed on src_png (already paletted),
    inside work_dir, producing work_dir/dst_name. Returns the output
    path. gfx2next requires a paletted 8-bit PNG - truecolour input is
    rejected."""
    dst_path = work_dir / dst_name
    if dst_path.exists():
        dst_path.unlink()
    proc = subprocess.run(
        [str(gfx2next), "-bitmap", "-pal-embed", src_png.name, dst_name],
        cwd=str(work_dir), capture_output=True, text=True,
    )
    if proc.returncode != 0 or not dst_path.exists():
        raise SystemExit(
            f"error: gfx2next failed (exit {proc.returncode})\n"
            f"stdout: {proc.stdout}\nstderr: {proc.stderr}"
        )
    return dst_path


def main(argv):
    ap = argparse.ArgumentParser(
        description="Convert a PNG to raw NX2/NXI format for NextDAAD "
                    "(ADAPTIVE 256-colour quantize -> gfx2next -bitmap "
                    "-pal-embed -> raw 512-byte palette + pixels).")
    ap.add_argument("src", help="source PNG (320-wide for .NX2, "
                                 "256-wide for .NXI)")
    ap.add_argument("out", help="destination file, e.g. OUT.NX2 or "
                                 "OUT.NXI")
    ap.add_argument("--crop-height", type=int, default=None,
                     help="crop the source to the top N rows before "
                          "conversion")
    ap.add_argument("--gfx2next", default=str(DEFAULT_GFX2NEXT),
                     help=f"gfx2next.exe path (default: {DEFAULT_GFX2NEXT})")
    args = ap.parse_args(argv[1:])

    gfx2next = Path(args.gfx2next)
    if not gfx2next.exists():
        raise SystemExit(f"error: gfx2next not found at {gfx2next}")

    src_path = Path(args.src)
    if not src_path.exists():
        raise SystemExit(f"error: source not found: {src_path}")
    out_path = Path(args.out)

    im = Image.open(src_path).convert("RGB")
    print(f"source {src_path}: {im.width}x{im.height}")

    if args.crop_height is not None:
        if args.crop_height <= 0 or args.crop_height > im.height:
            raise SystemExit(
                f"error: --crop-height {args.crop_height} is out of "
                f"range for a {im.height}-row source"
            )
        im = im.crop((0, 0, im.width, args.crop_height))
        print(f"cropped to {im.width}x{im.height}")

    width, height = im.width, im.height

    with tempfile.TemporaryDirectory(prefix="png2nx_") as tmp:
        work_dir = Path(tmp)
        idx_img = quantize(im, name=str(src_path))
        tmp_png = work_dir / "src.png"
        idx_img.save(tmp_png)

        tmp_nxi = run_gfx2next(gfx2next, work_dir, tmp_png, "out.nxi")
        data = tmp_nxi.read_bytes()

    expected = 512 + width * height
    if len(data) != expected:
        raise SystemExit(
            f"error: output size {len(data)} B does not match expected "
            f"{expected} B (512 palette + {width}x{height} pixels) - "
            f"refusing to write {out_path}"
        )

    out_path.write_bytes(data)
    print(f"wrote {out_path}: {len(data)} B ({width}x{height}, "
          f"512 B palette + {width * height} B pixels) - OK")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
