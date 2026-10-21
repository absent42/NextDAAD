# authoring-kit/lib/vidtune/__main__.py
import argparse
import os
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))  # lib siblings

from vidtune import quiet_wayland_textinput
quiet_wayland_textinput(os.environ)  # before any Qt import reads the rules

from PySide6.QtGui import QIcon
from PySide6.QtWidgets import QApplication, QFileDialog, QMessageBox

from vidtune import ICON_PATH, theme
from vidtune.kitmodel import find_kit_root
from vidtune.mainwindow import MainWindow


def parse_args(argv):
    """(game_dir, game_cfg), each a resolved Path or None. Set by
    lib/vidtune.ps1 from Resolve-KitGame; no --game-dir = legacy kit root."""
    ap = argparse.ArgumentParser(prog="vidtune")
    ap.add_argument("--game-dir", type=Path, default=None)
    ap.add_argument("--game-cfg", type=Path, default=None)
    args, _ = ap.parse_known_args(argv)  # Qt's own options pass through
    return tuple(p.resolve() if p is not None else None
                 for p in (args.game_dir, args.game_cfg))


def main():
    app = QApplication(sys.argv)
    # MainWindow styles itself too (so a test- or embedder-constructed
    # window is themed); doing it here as well is what catches the
    # things that are NOT its children - the kit picker below, message
    # boxes, menus - so the tool has one look end to end.
    app.setFont(theme.ui_font())
    app.setStyleSheet(theme.stylesheet())
    app.setWindowIcon(QIcon(str(ICON_PATH)))  # kit picker, message boxes
    game_dir, game_cfg = parse_args(sys.argv[1:])
    root = find_kit_root(Path.cwd())
    if root is None:
        picked = QFileDialog.getExistingDirectory(
            None, "Open kit folder (contains CONFIG.BAT and the lib folder)")
        root = find_kit_root(picked) if picked else None
    if root is None:
        QMessageBox.critical(None, "vidtune",
                             "No kit found - a kit folder contains "
                             "CONFIG.BAT and a lib folder.")
        return 1
    win = MainWindow(root, game_dir, game_cfg)
    win.show()
    return app.exec()


if __name__ == "__main__":
    sys.exit(main())
