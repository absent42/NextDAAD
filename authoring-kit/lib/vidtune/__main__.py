# authoring-kit/lib/vidtune/__main__.py
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))  # lib siblings

from PySide6.QtWidgets import QApplication, QFileDialog, QMessageBox

from vidtune.kitmodel import find_kit_root
from vidtune.mainwindow import MainWindow


def main():
    app = QApplication(sys.argv)
    root = find_kit_root(Path.cwd())
    if root is None:
        picked = QFileDialog.getExistingDirectory(
            None, "Open kit folder (contains CONFIG.BAT and VIDEO)")
        root = find_kit_root(picked) if picked else None
    if root is None:
        QMessageBox.critical(None, "vidtune",
                             "No kit found - a kit folder contains "
                             "CONFIG.BAT and a VIDEO directory.")
        return 1
    win = MainWindow(root)
    win.show()
    return app.exec()


if __name__ == "__main__":
    sys.exit(main())
