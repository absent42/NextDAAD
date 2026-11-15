"""Ingest one silicon leg into the tracked results tree.

Usage: python tests/core303/ingest.py <leg_dir> --board ks1 --leg leg1
           [--date YYYY-MM-DD] [--nxb-baseline LOG --allow FILE]
       python tests/core303/ingest.py --verify-staged <dir>
"""
import argparse
import datetime
import hashlib
import os
import re
import shutil
import sys
from pathlib import Path

import parse
from parse import LogError

NAME = re.compile(r"[A-Za-z0-9_]+")


class IngestError(Exception):
    pass


def _first_line(path):
    with open(path, "rb") as f:
        return f.readline().decode("ascii", "replace").rstrip("\r\n")


def _gates(leg_dir):
    """GATES.TXT as {key: value} (first occurrence); needs a usable stamp: or bundle:."""
    g = leg_dir / "GATES.TXT"
    if not g.is_file():
        raise IngestError("GATES.TXT missing in %s" % leg_dir)
    keys = {}
    for line in g.read_text(encoding="ascii", errors="replace").splitlines():
        k, sep, v = line.partition(":")
        if sep and k not in keys:
            keys[k] = v.strip()
    if "stamp" not in keys and "bundle" not in keys:
        raise IngestError("GATES.TXT has neither stamp: nor bundle: line")
    if "stamp" in keys and (not keys["stamp"] or keys["stamp"].endswith("-dirty")):
        raise IngestError("GATES.TXT stamp unusable: %r" % keys["stamp"])
    if "bundle" in keys and not re.fullmatch(r"[0-9a-f]{12}", keys["bundle"]):
        raise IngestError("GATES.TXT bundle unusable: %r" % keys["bundle"])
    return keys


GATE_KEYS = ("quiet_check:", "bench_check:")


def _gates_section(leg_dir, keys):
    """report.md tail: the GATES.TXT quiet and bench check lines, under Gates. A
    stamp-only leg lists a missing check; a bundle leg lists only those present."""
    text = (leg_dir / "GATES.TXT").read_text(encoding="ascii", errors="replace")
    got = [l.strip() for l in text.splitlines() if l.startswith(GATE_KEYS)]
    if "bundle" not in keys:
        for k in GATE_KEYS:
            if not any(l.startswith(k) for l in got):
                got.append("%s MISSING from GATES.TXT" % k)
    return "## Gates\n\n" + "".join("- %s\n" % l for l in got)


def _raw_logs(leg_dir):
    found = sorted(p for p in leg_dir.iterdir() if p.is_file() and (
        p.suffix.upper() == ".LOG" or
        (p.name.upper().startswith("NXBENCH") and p.suffix.upper() == ".TXT")))
    out = leg_dir / "out"
    if out.is_dir():
        found += sorted(p for p in out.iterdir() if p.is_file() and p.suffix.upper() == ".LOG")
    if not found:
        raise IngestError("no logs in %s" % leg_dir)
    return found


def _last_run(raw):
    """Bytes of the last #CORE303 run in an SD log (the writer appends runs)."""
    start = 0 if raw.startswith(b"#CORE303") else -1
    i = raw.find(b"\n#CORE303")
    while i != -1:
        start = i + 1
        i = raw.find(b"\n#CORE303", i + 1)
    return raw[max(start, 0):]


def _pi_read_lines(raws):
    """PI-READ findings: each PI_<NAME>.LOG against the last run of <NAME>.LOG."""
    by_name = {p.name: p for p in raws}
    lines, paired = [], set()
    for p in raws:
        if not p.name.startswith("PI_") or _first_line(p).startswith("#PI303"):
            continue
        sd = by_name.get(p.name[3:])
        if sd is None:
            lines.append("PI-READ NO-SD-COPY %s" % p.name)
            continue
        paired.add(p)
        want, got = _last_run(sd.read_bytes()), p.read_bytes()
        if want == got:
            lines.append("PI-READ MATCH %s" % sd.name)
        else:
            off = next((i for i, (a, b) in enumerate(zip(want, got)) if a != b),
                       min(len(want), len(got)))
            lines.append("PI-READ MISMATCH first_offset=%d %s" % (off, sd.name))
    return lines, paired


def _frames_lines(pis, keys):
    """FRAMES findings: each Pi log's #PIENV frames_hash against GATES.TXT frames:."""
    want = keys.get("frames") or "none"
    out = []
    for p, pl in pis:
        got = pl.env.get("frames_hash")
        if got is None:
            continue
        if got == want:
            out.append("FRAMES MATCH %s" % p.name)
        else:
            out.append("FRAMES MISMATCH %s frames_hash=%s gates=%s" % (p.name, got, want))
    return out


def _unit_by_tag(logs):
    """First T/unit (or T/frame) per tag across CORE303 logs; unusable rows skipped."""
    out = {}
    for log in logs:
        try:
            lpf, tpl = parse.timing(log.nr)
        except LogError:
            continue
        for r in log.rows:
            if r.tag in out or r.ck_ok is False:
                continue
            f = parse.isr_per_frame if parse.TAGS[r.tag].per_frame else parse.per_unit
            v = f(log, r, lpf, tpl)
            if v is not None:
                out[r.tag] = v
    return out


def _ks_compare(results, board, leg, cores):
    """KS1/KS3 lines for tags in this ks3 leg and the latest ks1 sitting of the same leg."""
    if board != "ks3":
        return []
    prior = sorted(p for p in results.glob("*-ks1-" + leg) if p.is_dir())
    if not prior:
        return []
    old = []
    for p in sorted(prior[-1].glob("*.LOG")):
        if _first_line(p).startswith("#CORE303 "):
            old.append(parse.parse_log(p))
    a, b = _unit_by_tag(old), _unit_by_tag([c[1] for c in cores])
    return ["KS1/KS3 %s ks1=%s ks3=%s" % (t, parse._fmt(a[t]), parse._fmt(b[t]))
            for t in a if t in b]


def _nr_line(path):
    for line in path.read_text(encoding="ascii").splitlines():
        if line.startswith("#NR "):
            return line
    raise IngestError("no #NR line in %s" % path)


def _leg1(results, date, board):
    folder = results / ("%s-%s-leg1" % (date, board))
    if not folder.is_dir():
        raise IngestError("leg 1 not ingested yet: %s" % folder.name)
    for p in sorted(folder.glob("*.LOG")):
        if _first_line(p).startswith("#CORE303 "):
            log = parse.parse_log(p)
            return folder.name, _nr_line(p), log
    raise IngestError("no CORE303 log in %s" % folder.name)


def ingest(leg_dir, board, leg, date, results, nxb_baseline=None, allow=None):
    leg_dir, results = Path(leg_dir), Path(results)
    for v in (board, leg):
        if not NAME.fullmatch(v):
            raise IngestError("bad name: %r" % v)
    if not re.fullmatch(r"\d{4}-\d{2}-\d{2}", date):
        raise IngestError("bad date: %r" % date)
    dest = results / ("%s-%s-%s" % (date, board, leg))
    if dest.exists():
        raise IngestError("%s exists; sittings are never overwritten" % dest.name)
    tmp = results / ("." + dest.name + ".partial")
    if tmp.exists():
        raise IngestError("%s exists from a crashed run; remove it" % tmp.name)
    idx = results / "INDEX.md"
    if not idx.is_file():
        raise IngestError("INDEX.md missing in %s" % results)
    old_index = idx.read_bytes()
    sep = b"" if old_index.endswith(b"\n") else b"\n"
    keys = _gates(leg_dir)
    stamp = keys.get("stamp")
    raws = _raw_logs(leg_dir)
    pi_read, paired = _pi_read_lines(raws)
    cores, nxbs, pis = [], [], []
    try:
        for p in raws:
            if p in paired:
                continue
            first = _first_line(p)
            if first.startswith("#NXB"):
                nxbs.append(p)
            elif first.startswith("#PI303"):
                pl = parse.parse_pilog(p)
                if pl.bundle != keys.get("bundle"):
                    raise IngestError("%s bundle %s != GATES.TXT %s" % (
                        p.name, pl.bundle, keys.get("bundle")))
                pis.append((p, pl))
            elif p.name.startswith("PI_"):
                continue
            else:
                log = parse.parse_log(p)
                if log.stamp != stamp:
                    raise IngestError("%s stamp %s != GATES.TXT %s" % (p.name, log.stamp, stamp))
                cores.append((p, log))
        timing_from = None
        ref = cores[0] if cores else None
        nr, nr_line_out, tm = {}, None, None
        if nxbs and not cores:
            timing_from, nr_line, ref_log = _leg1(results, date, board)
            nr, nr_line_out = ref_log.nr, nr_line
        elif ref:
            nr = ref[1].nr
            nr_line_out = _nr_line(ref[0])
        elif not pis:
            raise IngestError("no CORE303, NXB or PI303 log")
        if nr:
            tm = parse.timing(nr)
        nxb = None
        for p in nxbs:
            nxb = (nxb or []) + parse.parse_nxb(p)
        base = parse.parse_nxb(nxb_baseline) if nxb_baseline else None
        tags = []
        if allow:
            tags = [t.strip() for t in Path(allow).read_text().splitlines() if t.strip()]
        if cores or nxb:
            text = parse.report([c[1] for c in cores], nxb, base, timing=tm, ratio_tags=tags)
        else:
            text = ""
        if pis:
            text += parse.report_pi([pl for _, pl in pis], [c[1] for c in cores])
        extra = _ks_compare(results, board, leg, cores) + pi_read + _frames_lines(pis, keys)
        if extra:
            text += "\n" + "\n".join(extra) + "\n"
        text += "\n" + _gates_section(leg_dir, keys)
    except LogError as e:
        raise IngestError(str(e))
    verdict = next((l for l in text.splitlines() if l.startswith("WAIT STATES:")), "ingested")

    tmp.mkdir()
    try:
        _write(tmp, leg_dir, raws, text, date, board, leg, keys, nr, nr_line_out,
               timing_from)
        os.rename(tmp, dest)
        row = "| %s | %s | %s | %s | %s |\n" % (date, board, leg, verdict, dest.name)
        new = results / "INDEX.md.tmp"
        new.write_bytes(old_index + sep + row.encode("ascii"))
        os.replace(new, idx)
    except BaseException:
        shutil.rmtree(tmp, ignore_errors=True)
        raise
    return dest


def _write(dest, leg_dir, raws, text, date, board, leg, keys, nr, nr_line_out,
           timing_from):
    for p in [leg_dir / "GATES.TXT"] + raws:
        to = dest / p.relative_to(leg_dir)
        to.parent.mkdir(exist_ok=True)
        shutil.copyfile(p, to)
    lines = ["date: " + date, "board: " + board, "leg: " + leg]
    lines += ["%s: %s" % (k, keys[k]) for k in ("stamp", "bundle", "rerun_of") if k in keys]
    if nr:
        lines += ["core: %02X.%02X" % (nr.get("01", 0), nr.get("0E", 0)),
                  "board_id: %02X" % nr.get("0F", 0)]
    lines += ["sd_folder: " + leg_dir.name,
              "logs: " + ",".join(str(p.relative_to(leg_dir)).replace("\\", "/")
                                  for p in raws)]
    if nr_line_out:
        lines.append("nr: " + nr_line_out)
    if timing_from:
        lines.append("timing_from: " + timing_from)
    (dest / "sitting.txt").write_bytes(("\n".join(lines) + "\n").encode("ascii"))
    (dest / "report.md").write_bytes(text.encode("ascii", "replace"))


REPO = Path(__file__).resolve().parents[2]


def _sha256(path):
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for blk in iter(lambda: f.read(1 << 20), b""):
            h.update(blk)
    return h.hexdigest()


def verify_staged(staged):
    """One line per file that does not match MANIFEST.txt: MISSING, MISMATCH or EXTRA.
    A path marked 'here' must be in the folder; any other is read from the folder when
    present, else from the tracked repo path. Logs and out/ are not checked for extras."""
    staged = Path(staged)
    man = staged / "MANIFEST.txt"
    if not man.is_file():
        return ["MISSING MANIFEST.txt"]
    bad, listed = [], {"MANIFEST.txt"}
    for line in man.read_text(encoding="ascii").splitlines():
        if not line.strip() or line.startswith("#"):
            continue
        parts = line.split()
        if len(parts) != 3:
            bad.append("MALFORMED %s" % line)
            continue
        want, rel, loc = parts
        listed.add(rel)
        f = staged / rel
        if not f.is_file() and loc != "here":
            f = REPO / loc
        if not f.is_file():
            bad.append("MISSING %s" % rel)
        elif _sha256(f) != want:
            bad.append("MISMATCH %s" % rel)
    for p in sorted(staged.rglob("*")):
        rel = p.relative_to(staged).as_posix()
        if p.is_file() and rel not in listed and p.suffix.upper() != ".LOG" \
                and not rel.startswith("out/"):
            bad.append("EXTRA %s" % rel)
    return bad


def main(argv=None):
    ap = argparse.ArgumentParser()
    ap.add_argument("leg_dir", nargs="?")
    ap.add_argument("--board")
    ap.add_argument("--leg")
    ap.add_argument("--date", default=datetime.date.today().isoformat())
    ap.add_argument("--nxb-baseline")
    ap.add_argument("--allow")
    ap.add_argument("--verify-staged", metavar="DIR")
    a = ap.parse_args(argv)
    if a.verify_staged:
        bad = verify_staged(a.verify_staged)
        for line in bad:
            print(line)
        return 1 if bad else 0
    if not (a.leg_dir and a.board and a.leg):
        ap.error("leg_dir, --board and --leg are required")
    results = Path(__file__).parent / "results"
    try:
        dest = ingest(Path(a.leg_dir), a.board, a.leg, a.date, results,
                      a.nxb_baseline and Path(a.nxb_baseline), a.allow and Path(a.allow))
    except (IngestError, OSError, UnicodeDecodeError) as e:
        sys.stderr.write("error: %s\n" % e)
        return 1
    print(dest)
    return 0


if __name__ == "__main__":
    sys.exit(main())
