"""Generate the authoring kit's HTML manual from manual/*.md.

Source lives at manual/ and NEVER ships. Output goes to
authoring-kit/docs/ which IS the shipped artefact - the same shape as
src/ -> build/nextdaad.nex -> authoring-kit/nextdaad.nex.

Every .md becomes a .html; every .png under manual/ is copied beside its
page (the manual embeds images by relative path); style.css is copied.
Generated .html and .png files whose source no longer exists are pruned,
so a deleted or renamed page cannot linger in the kit. Nothing else under
authoring-kit/docs/ is touched.

Run via build.ps1 -Kit, or directly for a quick regenerate.
"""
import re
import shutil
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
SRC = ROOT / "manual"
OUT = ROOT / "authoring-kit" / "docs"

try:
    import markdown
except ImportError:
    sys.exit(
        "ERROR: the 'markdown' package is required to build the manual.\n"
        "  pip install markdown\n"
        "Refusing to continue - skipping generation would ship stale HTML, "
        "which is the exact failure this pipeline exists to prevent."
    )

PAGE = """<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>{title} - NextDAAD</title>
<link rel="stylesheet" href="{css}">
</head>
<body>
<main>
{body}
</main>
</body>
</html>
"""


def title_of(md_text, fallback):
    """First H1 becomes the page title; filename is the fallback."""
    for line in md_text.splitlines():
        if line.startswith("# "):
            return line[2:].strip()
    return fallback


def main():
    if not SRC.is_dir():
        sys.exit(f"ERROR: no manual source at {SRC}")

    sources = sorted(SRC.rglob("*.md"))
    if not sources:
        sys.exit(f"ERROR: no .md files under {SRC}")

    OUT.mkdir(parents=True, exist_ok=True)
    produced = set()
    written = 0
    for md_path in sources:
        rel = md_path.relative_to(SRC)
        html_path = OUT / rel.with_suffix(".html")
        html_path.parent.mkdir(parents=True, exist_ok=True)

        text = md_path.read_text(encoding="utf-8")
        body = markdown.markdown(
            text, extensions=["tables", "fenced_code", "toc", "sane_lists"]
        )
        # Source documents link to each other as .md; the shipped pages are
        # .html. Anchored to href= on purpose: a blind replace would also
        # rewrite a literal .md" inside a code sample, silently corrupting
        # it, and code blocks are not escaped against that.
        body = re.sub(r'(href="[^"]*?)\.md(["#])', r'\1.html\2', body)
        depth = len(rel.parts) - 1
        css = ("../" * depth) + "style.css"
        html_path.write_text(
            PAGE.format(title=title_of(text, rel.stem), body=body, css=css),
            encoding="utf-8",
        )
        produced.add(html_path)
        written += 1

    # Images the pages embed by relative path ship beside them.
    copied = 0
    for png_path in sorted(SRC.rglob("*.png")):
        dest = OUT / png_path.relative_to(SRC)
        dest.parent.mkdir(parents=True, exist_ok=True)
        shutil.copyfile(png_path, dest)
        produced.add(dest)
        copied += 1

    css_src = SRC / "style.css"
    if not css_src.is_file():
        sys.exit(f"ERROR: missing {css_src}")
    shutil.copyfile(css_src, OUT / "style.css")

    pruned = prune_stale(produced)
    print(f"manual: {written} page(s), {copied} image(s), {pruned} pruned -> {OUT}")


def prune_stale(produced):
    """Delete generated .html/.png files this run did not produce - their
    source was deleted or renamed. Other files under OUT are left alone."""
    pruned = 0
    for path in sorted(OUT.rglob("*")):
        if path.is_file() and path.suffix.lower() in (".html", ".png") \
                and path not in produced:
            path.unlink()
            print(f"manual: pruned {path.relative_to(OUT)} (no source)")
            pruned += 1
    for folder in sorted((p for p in OUT.rglob("*") if p.is_dir()), reverse=True):
        if not any(folder.iterdir()):
            folder.rmdir()
    return pruned


if __name__ == "__main__":
    main()
