# scripts

Utility scripts for NextDAAD

- **png2nx.py** converts a PNG into the raw NX2/NXI picture format the interpreter loads directly (location art,
title screens): `python scripts\png2nx.py SRC.png OUT.NX2 [--crop-height N]` PIL ADAPTIVE 256-colour quantization, dither NONE, run through
tools\gfx2next\gfx2next.exe with -bitmap -pal-embed, producing a raw
512-byte palette followed by width*height pixel bytes (320-wide sources
make NX2, 256-wide sources make NXI - the engine derives height from
file size). Requires Python 3 and Pillow.
