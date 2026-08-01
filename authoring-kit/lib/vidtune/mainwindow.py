"""Main window shell: clip list, preview pane, settings panel, actions.

Three-pane Studio layout (owner-approved wireframe): clip list (~20%),
preview pane (~50%), settings panel in a scroll area (~30%), with an
action row, a bottom metrics strip and a status bar. PreviewPane
(playback, flicker toggle, heatmap, segment markers) lives in
previewpane.py and is re-exported here so
`from vidtune.mainwindow import PreviewPane` keeps working.
"""
import shutil
import tempfile
from pathlib import Path

import nxv2enc

from PySide6.QtCore import QLocale, Qt, Signal
from PySide6.QtGui import QDoubleValidator, QFont
from PySide6.QtWidgets import (
    QApplication,
    QCheckBox,
    QComboBox,
    QFormLayout,
    QGroupBox,
    QHBoxLayout,
    QLabel,
    QLineEdit,
    QListWidget,
    QListWidgetItem,
    QMainWindow,
    QMessageBox,
    QProgressBar,
    QPushButton,
    QScrollArea,
    QSplitter,
    QTextEdit,
    QVBoxLayout,
    QWidget,
)

from . import settingsmodel
from .configwrite import ConfigConflict, write_sidecar, write_vidopts_line
from .encoderun import EncodeJob, resolve_encoder, summarize_report
from .kitmodel import clip_state, list_clips, parse_config, read_generation_stamp
from .preview import extract_source
from .previewpane import PreviewPane
from .settingsmodel import KNOBS, SHAPE_PRESETS, VidprofileUnsupported, effective_settings

__all__ = ["MainWindow", "MetricsBar", "PreviewPane", "SettingsPanel"]


def to_seconds(value):
    """HH:MM:SS or plain seconds (str, int, float, or None) -> float
    seconds. Positional weights 3600/60/1, same rule video.ps1 uses for
    a clip-level --start; None (unset) is 0.0."""
    if value is None:
        return 0.0
    if isinstance(value, (int, float)):
        return float(value)
    parts = str(value).split(":")
    weights = (3600.0, 60.0, 1.0)[-len(parts):]
    return sum(float(p) * w for p, w in zip(parts, weights))


def _fmt_seconds(value):
    """Invariant decimal string for a seconds value - always dot-
    decimal (Python float str() never consults locale) and always
    keeps a fractional part (str(1.0) == '1.0', not the '1' that
    f'{1.0:g}' would give), matching the argv literals the encoder
    round-trips through write_sidecar/arg_hash."""
    return str(float(value))


def _strip_argv_flags(argv, flags):
    out = []
    i = 0
    while i < len(argv):
        if argv[i] in flags:
            i += 2
            continue
        out.append(argv[i])
        i += 1
    return out


def _parse_start_duration(argv):
    start = duration = None
    for i, tok in enumerate(argv):
        if tok == "--start" and i + 1 < len(argv):
            start = float(argv[i + 1])
        elif tok == "--duration" and i + 1 < len(argv):
            duration = float(argv[i + 1])
    return start, duration


class MetricsBar(QWidget):
    """Bottom strip: PSNR/bound-fraction/utilization/wire-bytes readout,
    a "go to worst burst" jump into the preview, an indeterminate
    progress bar + cancel button while a job runs, and (on job failure)
    a monospace read-only box with the encoder's raw output verbatim -
    policy: never paraphrase a gate refusal, show exactly what videnc
    printed."""

    cancel_requested = Signal()

    def __init__(self, parent=None):
        super().__init__(parent)
        self._preview = None
        self._burst_peak_frame = None

        self._psnr_label = QLabel("psnr: -")
        self._bound_label = QLabel("bound: -")
        self._goto_burst_btn = QPushButton("go")
        self._goto_burst_btn.setEnabled(False)
        self._goto_burst_btn.clicked.connect(self._on_goto_burst)
        self._util_label = QLabel("util: -")
        self._wire_label = QLabel("wire: -")
        self._status_label = QLabel("")

        self._progress = QProgressBar()
        self._progress.setRange(0, 0)          # indeterminate
        self._progress.setMaximumWidth(120)
        self._progress.setVisible(False)
        self._cancel_btn = QPushButton("Cancel")
        self._cancel_btn.setVisible(False)
        self._cancel_btn.clicked.connect(self.cancel_requested.emit)

        row = QHBoxLayout()
        row.setContentsMargins(0, 0, 0, 0)
        for w in (self._psnr_label, self._bound_label, self._goto_burst_btn,
                  self._util_label, self._wire_label, self._status_label):
            row.addWidget(w)
        row.addStretch(1)
        row.addWidget(self._progress)
        row.addWidget(self._cancel_btn)

        self._failure_box = QTextEdit()
        self._failure_box.setReadOnly(True)
        font = QFont("Courier New")
        font.setStyleHint(QFont.Monospace)
        self._failure_box.setFont(font)
        self._failure_box.setMaximumHeight(120)
        self._failure_box.setVisible(False)

        outer = QVBoxLayout(self)
        outer.setContentsMargins(4, 2, 4, 2)
        outer.addLayout(row)
        outer.addWidget(self._failure_box)

    def set_preview(self, preview):
        self._preview = preview

    def update_from(self, summary, pinned):
        self._failure_box.setVisible(False)
        self._failure_box.clear()
        self._psnr_label.setText(
            "psnr: -" if summary.psnr_mean is None
            else f"psnr: {summary.psnr_mean:.2f} dB")
        self._bound_label.setText(
            "bound: -" if summary.bound_fraction is None
            else f"bound: {summary.bound_fraction * 100:.1f}%")
        self._burst_peak_frame = summary.burst_peak_frame
        self._goto_burst_btn.setEnabled(self._burst_peak_frame is not None)
        if summary.util is None:
            util_text = "util: -"
        else:
            util_text = f"util: {summary.util:.2f}"
            if pinned:
                auto = summary.auto_budget
                util_text += (f" (auto {auto:g}, pinned)" if auto is not None
                             else " (pinned)")
        self._util_label.setText(util_text)
        self._wire_label.setText(
            "wire: -" if summary.wire_bytes is None
            else f"wire: {summary.wire_bytes} bytes")

    def set_status(self, text):
        self._status_label.setText(text)

    def status_text(self):
        return self._status_label.text()

    def start_job(self):
        self._failure_box.setVisible(False)
        self._status_label.setText("")
        self._progress.setVisible(True)
        self._cancel_btn.setVisible(True)

    def stop_job(self):
        self._progress.setVisible(False)
        self._cancel_btn.setVisible(False)

    def show_failure(self, raw_output):
        self._failure_box.setPlainText(raw_output)
        self._failure_box.setVisible(True)

    def _on_goto_burst(self):
        if self._preview is not None and self._burst_peak_frame is not None:
            self._preview.seek(self._burst_peak_frame)


def _float_validator(parent=None):
    """QDoubleValidator pinned to the C locale (dot decimal point), so
    input parsing does not depend on the host's system locale - every
    settings string and the encoder argv are dot-decimal."""
    validator = QDoubleValidator(parent)
    locale = QLocale(QLocale.C)
    locale.setNumberOptions(QLocale.RejectGroupSeparator)
    validator.setLocale(locale)
    return validator


def _choice_values(knob):
    if knob.name == "shape":
        return list(SHAPE_PRESETS)
    if knob.name == "retime":
        return ["blend", "drop", "mci"]
    if knob.name == "dither_mode":
        return ["offset", "mixture"]
    if knob.name == "width":
        return ["", "256", "320"]
    return []


class SettingsPanel(QWidget):
    """One row per Knob in KNOBS. Basic rows are always visible;
    advanced rows live in a collapsed, checkable QGroupBox. A row whose
    current value differs from kit_base is shown with a bold label and
    a reset button that restores the kit_base value."""

    changed = Signal()

    def __init__(self, parent=None):
        super().__init__(parent)
        self._kit_base = {}
        self._extra = []
        self._rows = {}
        self._updating = False

        self._basic_form = QFormLayout()
        self._advanced_group = QGroupBox("Advanced")
        self._advanced_group.setCheckable(True)
        self._advanced_group.setChecked(False)

        # setCheckable/setChecked alone only disables (grays out) a
        # QGroupBox's children in Qt - it never hides them. Collapse is
        # implemented explicitly: advanced rows live in an inner
        # container whose visibility follows the checkbox, starting
        # hidden to match the initial unchecked state.
        self._advanced_content = QWidget()
        self._advanced_form = QFormLayout(self._advanced_content)
        self._advanced_content.setVisible(False)
        group_layout = QVBoxLayout(self._advanced_group)
        group_layout.addWidget(self._advanced_content)
        self._advanced_group.toggled.connect(self._advanced_content.setVisible)

        self._extra_label = QLabel("")
        self._extra_label.setWordWrap(True)
        self._extra_label.setVisible(False)

        outer = QVBoxLayout(self)
        outer.addLayout(self._basic_form)
        outer.addWidget(self._advanced_group)
        outer.addWidget(self._extra_label)
        outer.addStretch(1)

        self._build_rows()

    def _build_rows(self):
        for knob in KNOBS:
            widget, getter, setter = self._make_widget(knob)
            reset_btn = QPushButton("reset")
            reset_btn.setVisible(False)
            reset_btn.clicked.connect(
                lambda checked=False, name=knob.name: self._reset(name))
            label = QLabel(knob.name)

            row_box = QHBoxLayout()
            row_box.setContentsMargins(0, 0, 0, 0)
            row_box.addWidget(widget, 1)
            row_box.addWidget(reset_btn)
            row_container = QWidget()
            row_container.setLayout(row_box)

            form = self._basic_form if knob.level == "basic" else self._advanced_form
            form.addRow(label, row_container)

            self._rows[knob.name] = {
                "knob": knob,
                "label": label,
                "widget": widget,
                "getter": getter,
                "setter": setter,
                "reset_btn": reset_btn,
            }

    def _make_widget(self, knob):
        if knob.kind == "choice":
            combo = QComboBox()
            combo.setEditable(True)
            for value in _choice_values(knob):
                combo.addItem(value)
            combo.currentTextChanged.connect(self._on_edit)

            def getter(combo=combo):
                text = combo.currentText()
                return text if text != "" else None

            def setter(value, combo=combo):
                combo.blockSignals(True)
                combo.setCurrentText("" if value is None else str(value))
                combo.blockSignals(False)

            return combo, getter, setter

        if knob.kind == "float":
            edit = QLineEdit()
            edit.setValidator(_float_validator(edit))
            edit.textChanged.connect(self._on_edit)

            def getter(edit=edit):
                text = edit.text()
                return text if text != "" else None

            def setter(value, edit=edit):
                edit.blockSignals(True)
                edit.setText("" if value is None else str(value))
                edit.blockSignals(False)

            return edit, getter, setter

        if knob.kind == "flag":
            box = QCheckBox()
            box.stateChanged.connect(self._on_edit)

            def getter(box=box):
                return box.isChecked()

            def setter(value, box=box):
                box.blockSignals(True)
                box.setChecked(bool(value))
                box.blockSignals(False)

            return box, getter, setter

        # str
        edit = QLineEdit()
        edit.textChanged.connect(self._on_edit)

        def getter(edit=edit):
            text = edit.text()
            return text if text != "" else None

        def setter(value, edit=edit):
            edit.blockSignals(True)
            edit.setText("" if value is None else str(value))
            edit.blockSignals(False)

        return edit, getter, setter

    def set_settings(self, settings, kit_base):
        self._updating = True
        self._kit_base = dict(kit_base)
        self._extra = list(settings.get("extra", []))
        for name, row in self._rows.items():
            row["setter"](settings.get(name))
        self._extra_label.setText(" ".join(self._extra))
        self._extra_label.setVisible(bool(self._extra))
        self._updating = False
        self._refresh_deviations()

    def get_settings(self):
        out = {name: row["getter"]() for name, row in self._rows.items()}
        out["extra"] = list(self._extra)
        return out

    def _on_edit(self, *args):
        if self._updating:
            return
        self._refresh_deviations()
        self.changed.emit()

    def _refresh_deviations(self):
        for name, row in self._rows.items():
            deviating = row["getter"]() != self._kit_base.get(name)
            font = row["label"].font()
            font.setBold(deviating)
            row["label"].setFont(font)
            row["reset_btn"].setVisible(deviating)

    def _reset(self, name):
        row = self._rows[name]
        row["setter"](self._kit_base.get(name))
        self._refresh_deviations()
        self.changed.emit()


class MainWindow(QMainWindow):
    def __init__(self, kit_root: Path):
        super().__init__()
        self.kit_root = Path(kit_root)
        self.cfg = parse_config(self.kit_root / "CONFIG.BAT")
        self.cfg_mtime = (self.kit_root / "CONFIG.BAT").stat().st_mtime
        self.stamp = read_generation_stamp(self.kit_root)
        self.clips = list_clips(self.kit_root)
        self.kit_base = settingsmodel._kit_base(self.cfg)
        self.session_edits: dict = {}
        self._current_clip = None

        # Session-only budget pins and "last successful full encode"
        # argv, per clip num3 - both reset when the window closes.
        self.pinned_budgets: dict = {}
        self.full_ok: dict = {}

        self.scratch_dir = Path(tempfile.mkdtemp(prefix="vidtune-"))
        self.encoder_argv = resolve_encoder(self.kit_root, self.cfg.toolsdir)
        self.ffmpeg = self._resolve_ffmpeg()

        self._job = None
        self._job_kind = None
        self._job_num3 = None
        self._job_output = None
        self._job_argv = None
        self._job_lines = []
        self._all_queue = []
        self._all_cancelled = False

        self.setWindowTitle("vidtune")

        self._banner = QLabel("")
        self._banner.setStyleSheet(
            "background-color: #a02020; color: white; padding: 4px;")
        self._banner.setVisible(False)
        self._banner.setWordWrap(True)

        self.clip_list = QListWidget()

        self.settings_panel = SettingsPanel()
        settings_scroll = QScrollArea()
        settings_scroll.setWidgetResizable(True)
        settings_scroll.setWidget(self.settings_panel)

        self.preview = PreviewPane()

        left_pane = QWidget()
        left_layout = QVBoxLayout(left_pane)
        left_layout.setContentsMargins(0, 0, 0, 0)
        left_layout.addWidget(self._banner)
        left_layout.addWidget(self.clip_list)

        splitter = QSplitter(Qt.Horizontal)
        splitter.addWidget(left_pane)
        splitter.addWidget(self.preview)
        splitter.addWidget(settings_scroll)
        splitter.setStretchFactor(0, 20)
        splitter.setStretchFactor(1, 50)
        splitter.setStretchFactor(2, 30)
        splitter.setSizes([200, 500, 300])

        self.preview_button = QPushButton("Preview Segment")
        self.encode_button = QPushButton("Encode Full")
        self.accept_button = QPushButton("Accept")
        self.accept_button.setEnabled(False)
        self.encode_all_button = QPushButton("Encode All Stale")

        actions_row = QHBoxLayout()
        actions_row.addWidget(self.preview_button)
        actions_row.addWidget(self.encode_button)
        actions_row.addWidget(self.accept_button)
        actions_row.addStretch(1)
        actions_row.addWidget(self.encode_all_button)

        self.metrics_bar = MetricsBar()
        self.metrics_bar.set_preview(self.preview)

        central = QWidget()
        central_layout = QVBoxLayout(central)
        central_layout.addWidget(splitter)
        central_layout.addLayout(actions_row)
        central_layout.addWidget(self.metrics_bar)
        self.setCentralWidget(central)

        if self.stamp is None:
            self.statusBar().addPermanentWidget(QLabel(
                "lib/video.ps1 stamp not found - staleness tracking unreliable"))
        if self.encoder_argv is None:
            self.statusBar().addPermanentWidget(QLabel(
                "no encoder found - videnc.exe missing and no Python 3 with "
                "Pillow + numpy; encode actions are disabled"))
            self.preview_button.setEnabled(False)
            self.encode_button.setEnabled(False)
            self.encode_all_button.setEnabled(False)

        self.preview_button.clicked.connect(self.on_preview_segment)
        self.encode_button.clicked.connect(self.on_encode_full)
        self.accept_button.clicked.connect(self.on_accept)
        self.encode_all_button.clicked.connect(self.on_encode_all_stale)
        self.metrics_bar.cancel_requested.connect(self._on_cancel_requested)
        self.settings_panel.changed.connect(self._update_accept_enabled)

        self.clip_list.currentItemChanged.connect(self._on_current_item_changed)
        self._populate_clip_list()
        if self.clip_list.count():
            self.clip_list.setCurrentRow(0)

    def _resolve_ffmpeg(self):
        p = Path(self.cfg.toolsdir, "ffmpeg", "bin", "ffmpeg.exe")
        if not p.is_absolute():
            p = self.kit_root / p
        return p

    def closeEvent(self, event):
        if self._job is not None:
            self._job.cancel()
        # A parent window closing does not propagate closeEvent to child
        # widgets in Qt - PreviewPane's own closeEvent blocks until any
        # in-flight decode QThread finishes (see previewpane.py); call it
        # explicitly, and BEFORE the scratch-dir cleanup below, so a
        # still-running decode is never left reading a .vid file out
        # from under an rmtree (and so the QThread is never torn down
        # while still running, which Qt does not tolerate).
        self.preview.close()
        shutil.rmtree(self.scratch_dir, ignore_errors=True)
        super().closeEvent(event)

    def _populate_clip_list(self):
        self._banner.setVisible(False)
        self._banner.setText("")
        self.clip_list.clear()
        try:
            for clip in self.clips:
                tuned, stale = clip_state(clip, self.cfg, self.stamp)
                if stale:
                    status = "stale"
                elif tuned:
                    status = "tuned"
                else:
                    status = "default"
                item = QListWidgetItem(f"{clip.num3}  {status}")
                item.setData(Qt.UserRole, clip.num3)
                self.clip_list.addItem(item)
        except VidprofileUnsupported as exc:
            self._banner.setText(str(exc))
            self._banner.setVisible(True)

    def _on_current_item_changed(self, current, previous):
        if current is None:
            return
        self.select_clip(current.data(Qt.UserRole))

    def select_clip(self, num3: str):
        if self._current_clip is not None:
            self.session_edits[self._current_clip] = self.settings_panel.get_settings()
        if num3 in self.session_edits:
            settings = self.session_edits[num3]
        else:
            settings = effective_settings(self.cfg, num3)
        self.settings_panel.set_settings(settings, self.kit_base)
        self._current_clip = num3
        self._update_accept_enabled()
        # A "budget provisional" (or other) status label belongs to the
        # clip that was open when it was set - it must not carry over
        # to a newly-selected clip with no job of its own running yet.
        # (The rest of the metrics strip - PSNR etc from update_from -
        # is pre-existing staleness on clip switch, out of scope here.)
        self.metrics_bar.set_status("")

    def _clip_by_num3(self, num3):
        for clip in self.clips:
            if clip.num3 == num3:
                return clip
        return None

    def _current_settings(self, num3):
        """The settings a clip's argv should be built from right now:
        the live panel widgets for whichever clip is open (session
        edits are not written back to self.session_edits until
        select_clip switches away from it), otherwise the last-saved
        session edit or, failing that, CONFIG.BAT's effective
        settings."""
        if num3 == self._current_clip:
            return self.settings_panel.get_settings()
        if num3 in self.session_edits:
            return self.session_edits[num3]
        return effective_settings(self.cfg, num3)

    def _argv_for_settings(self, settings):
        """Mirrors settingsmodel.build_arg_vector's shape/fps/vidopts/
        per-clip structure, but sources the per-clip tail from a live
        settings dict (deviations from kit_base) instead of CONFIG.BAT's
        raw per-clip string - build_arg_vector(cfg, num3) is exactly
        this function applied to effective_settings(cfg, num3)."""
        dev = settingsmodel.deviations(settings, self.cfg)
        per_has_shape = any(t in ("--shape", "--width", "--aspect") for t in dev)
        shape = [] if (per_has_shape or not self.cfg.vid_aspect) \
            else settingsmodel._shape_args(self.cfg.vid_aspect)
        fps = ["--fps", self.cfg.vid_fps] if self.cfg.vid_fps else []
        return shape + fps + settingsmodel.split_opts(self.cfg.vid_opts) + dev

    # -- argv construction ------------------------------------------------

    def preview_argv(self, num3):
        settings = self._current_settings(num3)
        argv = self._argv_for_settings(settings)
        seg = None
        if self.preview.seg_in is not None and self.preview.seg_out is not None:
            fps = float(settings.get("fps") or 25)
            seg = self.preview.segment_times(fps)
        if seg is not None:
            seg_start, seg_dur = seg
            base_start = to_seconds(settings.get("start"))
            argv = _strip_argv_flags(argv, ("--start", "--duration"))
            argv = argv + ["--start", _fmt_seconds(base_start + seg_start),
                           "--duration", _fmt_seconds(seg_dur)]
        # Pin is keyed by clip num3 only (not by the settings that were
        # in effect when it was captured) - it survives unrelated
        # settings edits for the rest of the session. It is deliberately
        # NOT invalidated on a settings change (e.g. a shape/duration
        # edit after a full encode still reuses the last pinned budget
        # for segment previews); full_argv never applies it, so a real
        # full encode always re-derives the budget from scratch anyway.
        if num3 in self.pinned_budgets and settings.get("stream_budget") is None:
            argv = argv + ["--stream-budget", _fmt_seconds(self.pinned_budgets[num3])]
        return argv

    def full_argv(self, num3):
        """Current panel settings only - never injects a budget pin;
        the shipping path (full encode, and BUILD.BAT/encode-all) always
        lets auto-budget re-derive from the actual full-length encode."""
        settings = self._current_settings(num3)
        return self._argv_for_settings(settings)

    # -- actions ------------------------------------------------------------

    def _set_actions_enabled(self, enabled):
        have_encoder = self.encoder_argv is not None
        self.preview_button.setEnabled(enabled and have_encoder)
        self.encode_button.setEnabled(enabled and have_encoder)
        self.encode_all_button.setEnabled(enabled and have_encoder)
        if enabled:
            self._update_accept_enabled()
        else:
            self.accept_button.setEnabled(False)

    def _update_accept_enabled(self):
        num3 = self._current_clip
        enabled = num3 is not None and self.full_ok.get(num3) == self.full_argv(num3)
        self.accept_button.setEnabled(bool(enabled))

    def _start_job(self, kind, num3, clip, output, argv):
        if self.encoder_argv is None:
            QMessageBox.critical(self, "vidtune",
                "No encoder available - videnc.exe not found and no "
                "Python 3 with Pillow + numpy on PATH.")
            return
        job = EncodeJob(self.encoder_argv, str(self.ffmpeg))
        self._job = job
        self._job_kind = kind
        self._job_num3 = num3
        self._job_output = Path(output)
        self._job_argv = list(argv)
        self._job_lines = []
        job.line.connect(self._job_lines.append)
        job.finished.connect(self._on_job_finished)
        self._set_actions_enabled(False)
        self.metrics_bar.start_job()
        job.start(clip.mp4, output, argv)

    def on_preview_segment(self):
        num3 = self._current_clip
        clip = self._clip_by_num3(num3) if num3 is not None else None
        if clip is None or self._job is not None:
            return
        output = self.scratch_dir / f"preview_{num3}.vid"
        self._start_job("preview", num3, clip, output, self.preview_argv(num3))

    def on_encode_full(self):
        num3 = self._current_clip
        clip = self._clip_by_num3(num3) if num3 is not None else None
        if clip is None or self._job is not None:
            return
        output = self.scratch_dir / f"full_{num3}.vid"
        self._start_job("full", num3, clip, output, self.full_argv(num3))

    def on_encode_all_stale(self):
        if self._job is not None:
            return
        self._all_queue = [c for c in self.clips
                           if clip_state(c, self.cfg, self.stamp)[1]]
        self._all_cancelled = False
        self._advance_all_queue()

    def _advance_all_queue(self):
        if self._all_cancelled or not self._all_queue:
            self._all_queue = []
            self._set_actions_enabled(True)
            return
        clip = self._all_queue.pop(0)
        argv = settingsmodel.build_arg_vector(self.cfg, clip.num3)
        self._start_job("all", clip.num3, clip, clip.vid, argv)

    def _on_cancel_requested(self):
        if self._job is None:
            return
        if self._job_kind == "all":
            # "cancel stops after the current clip" - let the in-flight
            # encode finish and land normally, just stop scheduling more.
            self._all_cancelled = True
        else:
            self._job.cancel()

    def on_accept(self):
        num3 = self._current_clip
        if num3 is None or self.full_ok.get(num3) != self.full_argv(num3):
            return   # guarded by the button state; defensive no-op
        if self.stamp is None:
            choice = QMessageBox.warning(
                self, "vidtune",
                "No generation stamp found (lib/video.ps1) - staleness "
                "tracking may disagree with the next build. Accept anyway?",
                QMessageBox.Yes | QMessageBox.No, QMessageBox.No)
            if choice != QMessageBox.Yes:
                return
        clip = self._clip_by_num3(num3)
        if clip is None:
            return
        settings = self._current_settings(num3)
        opts = " ".join(settingsmodel.deviations(settings, self.cfg))
        config_path = self.kit_root / "CONFIG.BAT"
        try:
            write_vidopts_line(config_path, num3, opts, expected_mtime=self.cfg_mtime)
        except ConfigConflict:
            choice = QMessageBox.warning(
                self, "vidtune",
                "CONFIG.BAT changed on disk since it was loaded - reload "
                "and try Accept again?",
                QMessageBox.Yes | QMessageBox.No, QMessageBox.No)
            if choice == QMessageBox.Yes:
                self._reload_config()
            return
        except RuntimeError as exc:
            QMessageBox.critical(self, "vidtune", str(exc))
            return

        # Sidecar args come from the SAVED config state (re-parsed after
        # the write), not the live settings dict - this is what makes
        # the sidecar hash match what a subsequent BUILD.BAT run would
        # compute from CONFIG.BAT alone.
        self.cfg = parse_config(config_path)
        self.cfg_mtime = config_path.stat().st_mtime
        saved_argv = settingsmodel.build_arg_vector(self.cfg, num3)
        shutil.copyfile(self.scratch_dir / f"full_{num3}.vid", clip.vid)
        write_sidecar(clip.sidecar, self.stamp or "", saved_argv)

        self.kit_base = settingsmodel._kit_base(self.cfg)
        self.full_ok.pop(num3, None)
        self._populate_clip_list()
        self._update_accept_enabled()

    def _reload_config(self):
        config_path = self.kit_root / "CONFIG.BAT"
        self.cfg = parse_config(config_path)
        self.cfg_mtime = config_path.stat().st_mtime
        self.stamp = read_generation_stamp(self.kit_root)
        self.kit_base = settingsmodel._kit_base(self.cfg)
        self._populate_clip_list()
        self._update_accept_enabled()

    # -- job completion -----------------------------------------------------

    def _on_job_finished(self, code, report):
        kind, num3 = self._job_kind, self._job_num3
        output, argv, lines = self._job_output, self._job_argv, self._job_lines
        self._job = None
        self.metrics_bar.stop_job()

        if code != 0:
            if kind == "all":
                self._all_queue = []
            self._set_actions_enabled(True)
            self.metrics_bar.show_failure("\n".join(lines))
            self.statusBar().showMessage(f"encode failed (exit {code}): {num3}")
            return

        summary = summarize_report(report)
        if kind == "preview":
            self._on_preview_success(num3, output, argv, summary)
            self._set_actions_enabled(True)
        elif kind == "full":
            self._on_full_success(num3, output, argv, summary)
            self._set_actions_enabled(True)
        elif kind == "all":
            self._on_all_success(num3, argv, summary)
            self._advance_all_queue()

    def _on_preview_success(self, num3, output, argv, summary):
        pinned = num3 in self.pinned_budgets
        self.metrics_bar.update_from(summary, pinned)
        if pinned:
            self.metrics_bar.set_status("")
        else:
            # No pin exists yet - this segment's auto-budget is only
            # provisional (derived from a short window, not the full
            # clip); label it on the metrics strip itself, not just the
            # window status bar, per the brief.
            self.metrics_bar.set_status("budget provisional (derived on segment)")
            self.statusBar().showMessage("budget provisional (derived on segment)")
        self._load_preview(num3, output, argv)

    def _on_full_success(self, num3, output, argv, summary):
        if summary.stream_budget is not None:
            self.pinned_budgets[num3] = summary.stream_budget
        self.full_ok[num3] = list(argv)
        self.metrics_bar.update_from(summary, num3 in self.pinned_budgets)
        # A full encode always derives the budget from the whole clip -
        # never provisional - so any stale "provisional" label from an
        # earlier segment preview must not linger.
        self.metrics_bar.set_status("")
        self._load_preview(num3, output, argv)
        self._update_accept_enabled()

    def _on_all_success(self, num3, argv, summary):
        clip = self._clip_by_num3(num3)
        write_sidecar(clip.sidecar, self.stamp or "", argv)
        self.metrics_bar.update_from(summary, num3 in self.pinned_budgets)
        self.metrics_bar.set_status("")
        self._populate_clip_list()

    # -- preview/source loading ----------------------------------------------

    def _load_preview(self, num3, vid_path, argv):
        source = self._extract_matching_source(num3, argv)
        self.preview.load(vid_path, source, column_major=False)

    def _resolve_dims(self, settings):
        aspect = settings.get("aspect")
        if aspect is not None:
            width = int(settings.get("width")) if settings.get("width") else 320
            return width, nxv2enc.derive_free_height(width, float(aspect))
        shape = settings.get("shape")
        if shape and "x" in shape.lower() and shape not in nxv2enc.PRESETS:
            w_str, h_str = shape.lower().split("x", 1)
            return int(w_str), int(h_str)
        return nxv2enc.resolve_shape(shape)

    def _extract_matching_source(self, num3, argv):
        """Best-effort: source frames shaped/retimed/trimmed to match
        the encode that just ran, for Flicker/Heatmap comparison. Runs
        ffmpeg synchronously on the GUI thread (busy cursor) - a known
        polish gap, not a correctness one: any failure here just drops
        back to an encoded-only preview, which PreviewPane already
        supports."""
        clip = self._clip_by_num3(num3)
        if clip is None or not clip.mp4.is_file():
            return None
        if self.ffmpeg is None or not Path(self.ffmpeg).is_file():
            return None
        try:
            settings = self._current_settings(num3)
            width, height = self._resolve_dims(settings)
            fps = float(settings.get("fps") or 25)
            retime = settings.get("retime") or "blend"
            start, duration = _parse_start_duration(argv)
            QApplication.setOverrideCursor(Qt.WaitCursor)
            try:
                return extract_source(str(self.ffmpeg), clip.mp4, width, height,
                                      fps, retime, start, duration)
            finally:
                QApplication.restoreOverrideCursor()
        except Exception:
            return None
