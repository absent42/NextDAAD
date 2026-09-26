# -*- mode: python ; coding: utf-8 -*-
# vidtune.exe (GUI) + videnc.exe (console) as one onedir bundle sharing _internal\.
# One build freezes both from the same sources, so the two can never drift apart.
#
# Build, verify and deploy with scripts\build-vidtools.ps1 (adds LICENSES\).
# Output: <out>\dist\vidtools\{vidtune.exe, videnc.exe, _internal\}
import os

LIB = os.path.abspath(os.path.join(SPECPATH, "..", "authoring-kit", "lib"))
ICON = os.path.join(LIB, "vidtune", "vidtune.ico")

# Sibling imports under lib\ are sys.path tricks PyInstaller cannot see.
GUI_HIDDEN = ["nxv2dec", "nxv2enc", "nxv2path", "videnc"]
CLI_HIDDEN = ["nxv2enc", "nxv2path"]

# Unused optional imports that drag in binaries. hashlib falls back to the
# built-in md5/blake2 without _hashlib, which drops OpenSSL.
EXCLUDES = [
    "ssl", "_ssl", "_hashlib",
    "yaml", "charset_normalizer", "psutil", "tkinter",
    "PIL._avif", "PIL.AvifImagePlugin", "PIL._webp", "PIL.WebPImagePlugin",
    "PIL._imagingcms", "PIL.ImageCms", "PIL._imagingtk", "PIL.ImageTk",
    "PySide6.QtNetwork",
]

# vidtune uses QtCore/QtGui/QtWidgets only. These arrive via Qt plugins:
# virtual keyboard -> Quick/Qml/OpenGL, qpdf -> Pdf, tls/netinfo/tuio -> Network.
QT_DROP_DLLS = {
    "qt6quick.dll", "qt6qml.dll", "qt6qmlmeta.dll", "qt6qmlmodels.dll",
    "qt6qmlworkerscript.dll", "qt6virtualkeyboard.dll", "qt6pdf.dll",
    "qt6network.dll", "qt6opengl.dll", "qt6svg.dll", "opengl32sw.dll",
}
QT_DROP_PLUGINS = (
    "pyside6/plugins/platforminputcontexts/",
    "pyside6/plugins/networkinformation/",
    "pyside6/plugins/tls/",
    "pyside6/plugins/generic/",
    "pyside6/plugins/iconengines/qsvgicon.dll",
    "pyside6/plugins/imageformats/qpdf.dll",
    "pyside6/plugins/imageformats/qsvg.dll",
    "pyside6/plugins/platforms/qdirect2d.dll",
    "pyside6/translations/",
)


def keep(entry):
    dest = entry[0].replace("\\", "/").lower()
    if dest.startswith("pyside6/") and os.path.basename(dest) in QT_DROP_DLLS:
        return False
    return not dest.startswith(QT_DROP_PLUGINS)


gui = Analysis(
    [os.path.join(LIB, "vidtune", "__main__.py")],
    pathex=[LIB],
    hiddenimports=GUI_HIDDEN,
    datas=[(ICON, "vidtune")],   # runtime window icon
    excludes=EXCLUDES,
    noarchive=False,
)
gui.binaries = [e for e in gui.binaries if keep(e)]
gui.datas = [e for e in gui.datas if keep(e)]

cli = Analysis(
    [os.path.join(LIB, "videnc.py")],
    pathex=[LIB],
    hiddenimports=CLI_HIDDEN,
    excludes=EXCLUDES,
    noarchive=False,
)

gui_exe = EXE(
    PYZ(gui.pure),
    gui.scripts,
    [],
    exclude_binaries=True,
    name="vidtune",
    icon=ICON,
    console=False,
    upx=False,
)
cli_exe = EXE(
    PYZ(cli.pure),
    cli.scripts,
    [],
    exclude_binaries=True,
    name="videnc",
    console=True,
    upx=False,
)

coll = COLLECT(
    gui_exe, gui.binaries, gui.datas,
    cli_exe, cli.binaries, cli.datas,
    upx=False,
    name="vidtools",
)
