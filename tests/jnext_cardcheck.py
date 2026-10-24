"""jNext card checker: jnext_cardcheck.py IMG CARDDIR SRCDIR

Exit 0 when no cluster on the card is owned twice, every file under /CARDDIR
is one cluster run, and each file's bytes equal the same path under SRCDIR.
       jnext_cardcheck.py --extract IMG /PATH/FILE OUTFILE   copy one card file out
Reads a FAT32 volume, bare or behind an MBR (type 0B/0C); LFN entries; 32-bit FAT.
"""
import os
import struct
import sys


class Fat32:
    def __init__(self, path):
        self.f = open(path, "rb")
        self.base = 0
        mbr = self.sector(0)
        if mbr[0x52:0x57] != b"FAT32":
            ptype = mbr[0x1BE + 4]
            if ptype not in (0x0B, 0x0C):
                raise SystemExit("unsupported partition type %02X" % ptype)
            self.base = struct.unpack_from("<I", mbr, 0x1BE + 8)[0] * 512
        bs = self.sector(0)
        if bs[0x52:0x57] != b"FAT32":
            raise SystemExit("not a FAT32 volume")
        self.bps = struct.unpack_from("<H", bs, 11)[0]
        self.spc = bs[13]
        rsv = struct.unpack_from("<H", bs, 14)[0]
        nfats = bs[16]
        fatsz = struct.unpack_from("<I", bs, 36)[0]
        self.root = struct.unpack_from("<I", bs, 44)[0]
        self.fat_off = self.base + rsv * self.bps
        self.data_off = self.base + (rsv + nfats * fatsz) * self.bps
        self.csize = self.spc * self.bps

    def sector(self, n):
        self.f.seek(self.base + n * 512)
        return self.f.read(512)

    def next(self, c):
        self.f.seek(self.fat_off + c * 4)
        return struct.unpack("<I", self.f.read(4))[0] & 0x0FFFFFFF

    def chain(self, c):
        out = []
        seen = set()
        while 2 <= c < 0x0FFFFFF8 and c not in seen:
            seen.add(c)
            out.append(c)
            c = self.next(c)
        return out

    def read_chain(self, c, size=None):
        data = b""
        for cl in self.chain(c):
            self.f.seek(self.data_off + (cl - 2) * self.csize)
            data += self.f.read(self.csize)
        return data if size is None else data[:size]

    def read_dir(self, c):
        data = self.read_chain(c)
        ents, lfn = [], ""
        for i in range(0, len(data), 32):
            e = data[i:i + 32]
            if e[0] == 0:
                break
            if e[0] == 0xE5:
                lfn = ""
                continue
            if e[11] == 0x0F:
                part = (e[1:11] + e[14:26] + e[28:32]).decode("utf-16-le", "ignore")
                lfn = part.split("\x00")[0] + lfn
                continue
            ext = e[8:11].decode("ascii", "replace").rstrip()
            short = e[0:8].decode("ascii", "replace").rstrip() + ("." + ext if ext else "")
            name = lfn or short
            lfn = ""
            if e[11] & 0x08:
                continue
            clus = (struct.unpack_from("<H", e, 20)[0] << 16) | struct.unpack_from("<H", e, 26)[0]
            size = struct.unpack_from("<I", e, 28)[0]
            ents.append((name, bool(e[11] & 0x10), clus, size))
        return ents

    def lookup(self, path):
        c = self.root
        for part in [p for p in path.split("/") if p]:
            for name, isdir, clus, _ in self.read_dir(c):
                if name.upper() == part.upper() and isdir:
                    c = clus
                    break
            else:
                raise SystemExit("not found on card: " + path)
        return c


def runs(chain):
    return 0 if not chain else 1 + sum(1 for a, b in zip(chain, chain[1:]) if b != a + 1)


def xlink(fs):
    """Walk the whole tree; return the count of clusters owned twice."""
    owner = {}
    bad = 0

    def claim(chain, who):
        nonlocal bad
        for c in chain:
            if c in owner:
                bad += 1
                if bad <= 10:
                    print("CROSS-LINK cluster %d: %s and %s" % (c, owner[c], who))
            else:
                owner[c] = who

    def walk(c, prefix):
        claim(fs.chain(c), prefix or "/")
        for name, isdir, clus, _ in fs.read_dir(c):
            if name in (".", ".."):
                continue
            if isdir:
                walk(clus, prefix + "/" + name)
            elif clus:
                claim(fs.chain(clus), prefix + "/" + name)

    walk(fs.root, "")
    print("clusters owned: %d, cross-linked: %d" % (len(owner), bad))
    return bad


def compare(fs, carddir, srcdir):
    """Each card file must be one run and equal its SRCDIR twin, and no SRCDIR file may be
    missing from the card; RUN.NEX stands for the single top-level *.NEX. Returns problems."""
    problems = 0
    count = 0
    seen = set()
    nexes = [n for n in os.listdir(srcdir) if n.upper().endswith(".NEX") and os.path.isfile(os.path.join(srcdir, n))]

    def walk(c, rel):
        nonlocal problems, count
        for name, isdir, clus, size in fs.read_dir(c):
            if name in (".", ".."):
                continue
            if isdir:
                walk(clus, rel + name + "/")
                continue
            count += 1
            r = runs(fs.chain(clus))
            if r > 1:
                problems += 1
                print("FRAGMENTED %s: %d runs" % (rel + name, r))
            src = os.path.join(srcdir, *(rel + name).split("/"))
            if not os.path.isfile(src):
                alt = [n for n in os.listdir(os.path.dirname(src) or ".")
                       if n.upper() == name.upper()] if os.path.isdir(os.path.dirname(src)) else []
                if alt:
                    src = os.path.join(os.path.dirname(src), alt[0])
                elif rel == "" and name.upper() == "RUN.NEX" and len(nexes) == 1:
                    src = os.path.join(srcdir, nexes[0])
                else:
                    problems += 1
                    print("EXTRA on card, not in source: " + rel + name)
                    continue
            seen.add(os.path.relpath(src, srcdir).replace(os.sep, "/").upper())
            with open(src, "rb") as f:
                want = f.read()
            got = fs.read_chain(clus, size) if clus else b""
            if got != want:
                problems += 1
                print("MISMATCH %s: card %d bytes, source %d bytes" % (rel + name, len(got), len(want)))

    walk(fs.lookup(carddir), "")
    for root, _, files in os.walk(srcdir):
        for fn in files:
            rp = os.path.relpath(os.path.join(root, fn), srcdir).replace(os.sep, "/")
            if rp.upper() not in seen:
                problems += 1
                print("MISSING from card: " + rp)
    print("files compared: %d, problems: %d" % (count, problems))
    return problems


def extract(img, path, out):
    fs = Fat32(img)
    parent, _, leaf = path.rstrip("/").rpartition("/")
    for name, isdir, clus, size in fs.read_dir(fs.lookup(parent)):
        if name.upper() == leaf.upper() and not isdir:
            with open(out, "wb") as f:
                f.write(fs.read_chain(clus, size))
            return 0
    print("not found on card: " + path)
    return 1


def main(argv):
    if len(argv) == 5 and argv[1] == "--extract":
        return extract(argv[2], argv[3], argv[4])
    if len(argv) != 4:
        print(__doc__)
        return 2
    fs = Fat32(argv[1])
    bad = xlink(fs) + compare(fs, argv[2], argv[3])
    return 1 if bad else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
