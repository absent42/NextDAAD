# tests/xbn/mkv2sav.py - a v2 save file (no state-area tail) for XLD2.
import pathlib, sys
ddb = pathlib.Path(sys.argv[1]).read_bytes()        # sd\XBN\GAME.DDB
n = ddb[3]                                          # HDR_NUMOBJ
out = b"NDSV" + bytes([1, n]) + bytes(256) + bytes(n) + bytes([1])
pathlib.Path(sys.argv[2]).write_bytes(out)
print("V2.SAV: %d objects, %d bytes" % (n, len(out)))
