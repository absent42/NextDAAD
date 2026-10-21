"""vidtune refuses to write into the shipped STARTER folder: Accept and
Encode Stale + Edited both stop with the StarterProtected message before
any file in STARTER is touched."""
from pathlib import Path

import pytest
from PySide6.QtCore import QObject, QTimer, Signal

from vidtune import mainwindow as vt_mainwindow
from vidtune.configwrite import STARTER_MESSAGE
from vidtune.mainwindow import MainWindow


class _FakeEncodeJob(QObject):
    line = Signal(str)
    finished = Signal(int, dict)

    def __init__(self, encoder_argv, ffmpeg):
        super().__init__()

    def start(self, input_path, output_path, args):
        Path(output_path).write_bytes(b"FAKEVID")
        QTimer.singleShot(0, lambda: self.finished.emit(0, {}))

    def cancel(self):
        pass


def _starter(kit, folder):
    s = kit / folder
    (s / "VIDEO").mkdir(parents=True)
    (s / "VIDEO" / "001.mp4").write_bytes(b"x")
    (s / "STARTER.DSF").write_bytes(b"")
    (s / "STARTER.CFG").write_bytes(b"@echo off\r\nSET VIDFPS=\r\n")
    return s


@pytest.fixture
def seen(monkeypatch):
    msgs = []
    monkeypatch.setattr(vt_mainwindow.QMessageBox, "critical",
                        staticmethod(lambda parent, title, text, *a: msgs.append(text)))
    return msgs


def _snapshot(folder):
    return {p.relative_to(folder): p.read_bytes()
            for p in folder.rglob("*") if p.is_file()}


@pytest.mark.parametrize("folder", ["STARTER", "starter"])
def test_encode_all_refused_in_starter(fixture_kit, qtbot, monkeypatch, seen, folder):
    monkeypatch.setattr(vt_mainwindow, "EncodeJob", _FakeEncodeJob)
    s = _starter(fixture_kit, folder)
    before = _snapshot(s)
    win = MainWindow(fixture_kit, s, s / "STARTER.CFG")
    qtbot.addWidget(win)
    win.encoder_argv = ["fake-encoder"]
    win.ffmpeg = Path("fake-ffmpeg.exe")
    assert win._stale_clips()          # the queue would not be empty
    win.on_encode_all_stale()
    qtbot.wait(50)
    assert seen == [STARTER_MESSAGE]
    assert win._job is None
    assert _snapshot(s) == before


@pytest.mark.parametrize("folder", ["STARTER", "starter"])
def test_accept_refused_in_starter(fixture_kit, qtbot, seen, folder):
    s = _starter(fixture_kit, folder)
    before = _snapshot(s)
    win = MainWindow(fixture_kit, s, s / "STARTER.CFG")
    qtbot.addWidget(win)
    win.stamp = "pal9k"
    win.select_clip("001")
    win.full_ok["001"] = win.full_argv("001")
    (win.scratch_dir / "full_001.vid").write_bytes(b"FAKEVID")
    win.on_accept()
    assert seen == [STARTER_MESSAGE]
    assert _snapshot(s) == before
