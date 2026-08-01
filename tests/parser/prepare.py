"""Compile one DSF to both interpreter targets so the two legs run
identical game logic.

Both targets are built WITHOUT -v3. DAAD Ready's ZXNEXT.BAT passes -v3 and
NextDAAD rejects the resulting V3 database at boot with
"NextDAAD: DDB bad header - E3"; HTML.BAT also passes -v3 but the html
target builds happily without it. Omitting it from both keeps the pair at
DAAD version 2.

Nothing is ever written into tools/. Every tool is invoked by absolute
path with cwd set to the work directory - note DRB drops 0.XMB into cwd.
"""
import shutil
import subprocess
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent.parent
DR = ROOT / "tools" / "DAAD-READY"
DRF = DR / "TOOLS" / "DRC" / "drf.exe"
DRB = DR / "TOOLS" / "DRC" / "drb.php"
PHP = DR / "PHP" / "PHP.exe"

# Fields that must match for the pair to be a valid differential test.
# "target" and "length" legitimately differ between the two builds.
LOGIC_FIELDS = ("version", "objects", "locations",
                "user_messages", "system_messages", "processes")


def ddb_header(path):
    b = Path(path).read_bytes()
    if len(b) < 8:
        raise ValueError("%s is too short to be a DDB" % path)
    if b[2] != 95:
        raise ValueError("%s: byte 2 is %d, expected the DDB signature 95"
                         % (path, b[2]))
    return {
        "version": b[0],
        "target": b[1],
        "objects": b[3],
        "locations": b[4],
        "user_messages": b[5],
        "system_messages": b[6],
        "processes": b[7],
        "length": len(b),
    }


def assert_matched(html_header, next_header):
    """Structural check only: compares the integer counts in the two
    headers (version, objects, locations, user messages, system
    messages, processes) and raises if any of them differ. Target
    nibble and byte length are expected to differ and are not compared.

    This cannot detect content differences - two DDBs with identical
    counts but different message text or different condact bytecode
    would pass this check undetected. The real guarantee that the pair
    describes the same game comes from both targets being compiled from
    the same source file within a single prepare_from_dsf() call, not
    from this comparison.
    """
    bad = [f for f in LOGIC_FIELDS if html_header[f] != next_header[f]]
    if bad:
        detail = ", ".join("%s: html=%r next=%r"
                           % (f, html_header[f], next_header[f]) for f in bad)
        raise ValueError("DDB pair is not a matched pair - %s" % detail)


def _run(args, cwd):
    res = subprocess.run([str(a) for a in args], cwd=str(cwd),
                         capture_output=True, text=True)
    if res.returncode != 0:
        raise RuntimeError("%s failed (%d):\n%s\n%s"
                           % (args[0], res.returncode, res.stdout, res.stderr))
    return res.stdout


def prepare_from_dsf(dsf_path, workdir, lang="EN"):
    """Build both targets from one DSF. Returns paths and headers."""
    workdir = Path(workdir)
    workdir.mkdir(parents=True, exist_ok=True)

    src = workdir / Path(dsf_path).name
    if Path(dsf_path).resolve() != src.resolve():
        shutil.copyfile(dsf_path, src)

    # html leg -> .jddb for jDAAD
    _run([DRF, "html", src.name, "html.json"], workdir)
    _run([PHP, DRB, "html", lang, "html.json", "html.DDB"], workdir)
    jddb = workdir / "html.jddb"
    if not jddb.exists():
        raise RuntimeError("DRB did not produce %s" % jddb)
    html_ddb = workdir / "html.DDB"
    if not html_ddb.exists():
        raise RuntimeError("DRB did not produce %s" % html_ddb)

    # zx next leg -> DDB for NextDAAD
    _run([DRF, "zx", "next", src.name, "next.json"], workdir)
    _run([PHP, DRB, "zx", "next", lang, "next.json", "next.ddb"], workdir)
    next_ddb = workdir / "next.ddb"
    if not next_ddb.exists():
        raise RuntimeError("DRB did not produce %s" % next_ddb)

    h_html = ddb_header(html_ddb)
    h_next = ddb_header(next_ddb)

    for name, h in (("html", h_html), ("next", h_next)):
        if h["version"] != 2:
            raise ValueError(
                "%s leg is DAAD version %d, expected 2 - check whether "
                "-v3 has crept into the DRF invocation for this target"
                % (name, h["version"]))

    assert_matched(h_html, h_next)

    # Stage the jDAAD runtime beside the game (read-only copy out of tools/).
    html_assets = DR / "ASSETS" / "HTML"
    for name in ("jdaad.js", "images.js", "extern.js"):
        srcf = html_assets / name
        if srcf.exists():
            shutil.copyfile(srcf, workdir / name)
    shutil.copyfile(jddb, workdir / "daad.jddb")

    return {
        "dsf": src,
        "jddb": jddb,
        "ddb": next_ddb,
        "header": {"html": h_html, "next": h_next},
    }


UNDRC = ROOT / "tools" / "unDRC" / "undrc.php"


def decompile(binary_path, workdir, extra_args=()):
    """Recover DSF source from a DDB, or from a TAP/SNA/BIN with -a.

    unDRC is invoked by absolute path with cwd in the work directory, so
    nothing is written into tools/. It emits <stem>.DSF into cwd.
    """
    workdir = Path(workdir)
    workdir.mkdir(parents=True, exist_ok=True)
    local = workdir / Path(binary_path).name
    if Path(binary_path).resolve() != local.resolve():
        shutil.copyfile(binary_path, local)

    _run([PHP, UNDRC, local.name] + list(extra_args), workdir)

    stem = local.stem
    for candidate in (workdir / (stem + ".DSF"), workdir / (stem + ".dsf")):
        if candidate.exists():
            return candidate
    produced = sorted(p.name for p in workdir.iterdir())
    raise RuntimeError("unDRC produced no DSF for %s (work dir holds: %s)"
                       % (binary_path, ", ".join(produced)))


def prepare_from_binary(binary_path, workdir, lang="EN", extra_args=()):
    """Decompile then build both targets.

    The round trip is lossy by design - both legs run the same recompiled
    source, so a lossy decompile still gives a valid differential test.
    A game that will not REBUILD is a different matter: it is out of
    corpus, and the compiler's own message is surfaced unchanged.

    Known: unDRC mis-decodes MOUSE's parameter count, desynchronising the
    process stream. Games using MOUSE cannot be ingested.
    """
    dsf = decompile(binary_path, workdir, extra_args=extra_args)
    try:
        return prepare_from_dsf(dsf, workdir, lang=lang)
    except RuntimeError as exc:
        raise RuntimeError(
            "unDRC round trip did not rebuild for %s - this game is out of "
            "corpus.\n%s" % (Path(binary_path).name, exc)) from exc
