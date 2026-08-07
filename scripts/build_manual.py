"""Generate the authoring kit's HTML manual from manual/*.md.

Source lives at manual/ and NEVER ships. Output goes to
authoring-kit/docs/ which IS the shipped artefact - the same shape as
src/ -> build/nextdaad.nex -> authoring-kit/nextdaad.nex.

Run via build.ps1 -Kit, or directly for a quick regenerate.
"""
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
    written = 0
    for md_path in sources:
        rel = md_path.relative_to(SRC)
        html_path = OUT / rel.with_suffix(".html")
        html_path.parent.mkdir(parents=True, exist_ok=True)

        text = md_path.read_text(encoding="utf-8")
        body = markdown.markdown(
            text, extensions=["tables", "fenced_code", "toc", "sane_lists"]
        )
        # Links between source documents point at .md; the shipped pages
        # are .html, so rewrite them.
        body = body.replace('.md"', '.html"').replace(".md#", ".html#")
        depth = len(rel.parts) - 1
        css = ("../" * depth) + "style.css"
        html_path.write_text(
            PAGE.format(title=title_of(text, rel.stem), body=body, css=css),
            encoding="utf-8",
        )
        written += 1

    css_src = SRC / "style.css"
    if not css_src.is_file():
        sys.exit(f"ERROR: missing {css_src}")
    shutil.copyfile(css_src, OUT / "style.css")

    print(f"manual: {written} page(s) -> {OUT}")


if __name__ == "__main__":
    main()
