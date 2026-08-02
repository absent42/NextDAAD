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

from PySide6.QtCore import QLocale, QRect, QSize, Qt, Signal
from PySide6.QtGui import (
    QColor,
    QDoubleValidator,
    QFont,
    QGuiApplication,
    QPainter,
)
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
    QStyle,
    QStyledItemDelegate,
    QStyleOptionViewItem,
    QTextEdit,
    QVBoxLayout,
    QWidget,
)

from . import settingsmodel, theme
from .configwrite import ConfigConflict, write_sidecar, write_vidopts_line
from .encoderun import EncodeJob, resolve_encoder, summarize_report
from .kitmodel import clip_state, list_clips, parse_config, read_generation_stamp
from .preview import extract_source
from .previewpane import PreviewPane, SOURCE_PREVIEW_HINT
from .settingsmodel import KNOBS, SHAPE_PRESETS, VidprofileUnsupported, effective_settings

__all__ = ["MainWindow", "MetricsBar", "PreviewPane", "SettingsPanel"]

# Owner-requested (2026-08-01): an un-encoded clip's source frames are
# loaded into the pane so the user can scrub/mark a segment before any
# encode has run (MainWindow._load_source_preview). Raw RGB24 frames are
# (width * height * 3) bytes EACH - a 320x256 60s 25fps clip alone is
# already ~350MB held live by the pane - so extraction is capped at this
# many seconds of the clip rather than pulling the whole thing. Frame
# indices still land on the SAME timeline the eventual encode will use
# (target fps, clip-level trim - see _resolve_extraction_params), so a
# marker set within the cap is still valid once a real encode runs.
SOURCE_PREVIEW_CAP_SECONDS = 60.0


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
    """--start/--duration values pulled from an argv list, in seconds.
    videnc documents --start as HH:MM:SS (a plain-seconds value is also
    legal input); to_seconds handles both. This used to call float()
    directly, which raised on any HH:MM:SS value and - via the broad
    except in _extract_matching_source - silently dropped the Flicker/
    Heatmap source comparison with no message at all."""
    start = duration = None
    for i, tok in enumerate(argv):
        if tok == "--start" and i + 1 < len(argv):
            start = to_seconds(argv[i + 1])
        elif tok == "--duration" and i + 1 < len(argv):
            duration = to_seconds(argv[i + 1])
    return start, duration


class _Meter(QWidget):
    """One reading: a demoted caption over the figure itself.

    "psnr: 30.00 dB" as a single run of body text gives the label and
    the number equal billing, so a strip of them reads as a sentence
    nobody scans. Splitting them lets the figure lead on size and
    weight while the caption drops to tertiary ink - the same reading,
    an order of magnitude faster to take in."""

    def __init__(self, caption, parent=None):
        super().__init__(parent)
        self.caption = QLabel(caption)
        self.caption.setFont(theme.caption_font())
        self.caption.setStyleSheet(f"color: {theme.INK_FAINT};")
        self.value = QLabel("-")
        self.value.setFont(theme.figure_font(11, bold=True))
        self.value.setStyleSheet(f"color: {theme.INK};")

        box = QVBoxLayout(self)
        box.setContentsMargins(0, 0, 0, 0)
        box.setSpacing(1)
        box.addWidget(self.caption)
        box.addWidget(self.value)

    def set_value(self, text, colour=None):
        self.value.setText(text)
        self.value.setStyleSheet(f"color: {colour or theme.INK};")

    def set_caption(self, text):
        self.caption.setText(text)


class MetricsBar(QWidget):
    """Bottom strip: PSNR/bound-fraction/utilization/wire-bytes readout,
    a "go to worst burst" jump into the preview, an indeterminate
    progress bar + cancel button while a job runs, and (on job failure)
    a monospace read-only box with the encoder's raw output verbatim -
    policy: never paraphrase a gate refusal, show exactly what videnc
    printed.

    Each reading is a _Meter (caption over figure). The `_psnr_label`/
    `_bound_label`/`_util_label`/`_wire_label` attributes still exist and
    are still the QLabels carrying the figures - they now hold the value
    alone ("30.00 dB"), with the name of the reading in the meter's
    caption rather than inlined into the same string."""

    cancel_requested = Signal()

    def __init__(self, parent=None):
        super().__init__(parent)
        self._preview = None
        self._burst_peak_frame = None

        # Identity chip, not a meter: it names what every figure beside
        # it describes, so it leads the strip and takes the accent.
        self._clip_label = QLabel("")
        self._clip_label.setFont(theme.figure_font(10, bold=True))
        self._clip_label.setStyleSheet(
            f"color: {theme.ACCENT};"
            f"border: 1px solid {theme.rgba(theme.ACCENT, 0.35)};"
            f"border-radius: {theme.RADIUS_CONTROL}px;"
            f"padding: {theme.UNIT}px {theme.GAP_ROW}px;")

        self._psnr_meter = _Meter("psnr")
        self._bound_meter = _Meter("budget-bound")
        self._util_meter = _Meter("utilisation")
        self._wire_meter = _Meter("wire")
        self._psnr_label = self._psnr_meter.value
        self._bound_label = self._bound_meter.value
        self._util_label = self._util_meter.value
        self._wire_label = self._wire_meter.value

        # The encoder's worst BURST WINDOW - not the same thing as the
        # trace's tallest single bar, which is why this survives the
        # trace being clickable. Relabelled from "go", which said
        # nothing about where it went.
        self._goto_burst_btn = QPushButton("worst burst")
        self._goto_burst_btn.setToolTip(
            "jump the preview to the encoder's worst burst window")
        self._goto_burst_btn.setEnabled(False)
        self._goto_burst_btn.clicked.connect(self._on_goto_burst)

        self._status_label = QLabel("")
        self._status_label.setStyleSheet(f"color: {theme.PHOSPHOR};")

        self._progress = QProgressBar()
        self._progress.setRange(0, 0)          # indeterminate
        self._progress.setMaximumWidth(120)
        self._progress.setVisible(False)
        self._cancel_btn = QPushButton("Cancel")
        self._cancel_btn.setVisible(False)
        self._cancel_btn.clicked.connect(self.cancel_requested.emit)

        row = QHBoxLayout()
        row.setContentsMargins(0, 0, 0, 0)
        row.setSpacing(theme.GAP_ZONE)
        row.addWidget(self._clip_label)
        row.addWidget(self._psnr_meter)
        row.addWidget(self._bound_meter)
        row.addWidget(self._util_meter)
        row.addWidget(self._wire_meter)
        # After the meters, not wedged between two of them: a button in
        # the middle of the run breaks the rhythm the four readings
        # otherwise read as.
        row.addWidget(self._goto_burst_btn)
        row.addWidget(self._status_label)
        row.addStretch(1)
        row.addWidget(self._progress)
        row.addWidget(self._cancel_btn)

        self._failure_box = QTextEdit()
        self._failure_box.setReadOnly(True)
        font = theme.figure_font(9)
        font.setStyleHint(QFont.Monospace)
        self._failure_box.setFont(font)
        self._failure_box.setMaximumHeight(120)
        self._failure_box.setStyleSheet(
            f"border: 1px solid {theme.rgba(theme.FAULT, 0.5)};")
        self._failure_box.setVisible(False)

        outer = QVBoxLayout(self)
        outer.setContentsMargins(0, theme.GAP_ROW, 0, 0)
        outer.setSpacing(theme.GAP_ROW)
        outer.addLayout(row)
        outer.addWidget(self._failure_box)

    def set_preview(self, preview):
        self._preview = preview

    def clip_tag(self):
        return self._clip_label.text()

    def clear(self, num3=None):
        """Resets the metrics figures to their empty state and updates
        the clip tag. Called from MainWindow.select_clip on every clip
        switch so a stale job's numbers (or a job that finishes for a
        clip the user has since switched away from) never gets shown
        without saying which clip it actually describes."""
        for meter in (self._psnr_meter, self._bound_meter,
                      self._util_meter, self._wire_meter):
            meter.set_value("-", theme.INK_GHOST)
        self._util_meter.set_caption("utilisation")
        self._burst_peak_frame = None
        self._goto_burst_btn.setEnabled(False)
        self._failure_box.setVisible(False)
        self._failure_box.clear()
        self._clip_label.setText(f"clip {num3}" if num3 is not None else "")

    def update_from(self, summary, pinned, num3=None):
        self._failure_box.setVisible(False)
        self._failure_box.clear()
        if num3 is not None:
            self._clip_label.setText(f"clip {num3}")
        self._psnr_meter.set_value(
            "-" if summary.psnr_mean is None
            else f"{summary.psnr_mean:.2f} dB",
            None if summary.psnr_mean is not None else theme.INK_GHOST)
        self._bound_meter.set_value(
            "-" if summary.bound_fraction is None
            else f"{summary.bound_fraction * 100:.1f}%",
            None if summary.bound_fraction is not None else theme.INK_GHOST)
        self._burst_peak_frame = summary.burst_peak_frame
        self._goto_burst_btn.setEnabled(self._burst_peak_frame is not None)

        # Utilisation is the figure that decides whether a clip ships, so
        # it is the one reading allowed to change colour: at or over 1.0
        # the stream does not fit, and just under it there is no room
        # left for a settings change to spend.
        if summary.util is None:
            self._util_meter.set_value("-", theme.INK_GHOST)
        else:
            if summary.util >= 1.0:
                colour = theme.FAULT
            elif summary.util >= 0.95:
                colour = theme.PHOSPHOR
            else:
                colour = None
            self._util_meter.set_value(f"{summary.util:.2f}", colour)
        # The pin is a qualifier on the reading, not part of it - it
        # belongs on the demoted caption line so the figure stays clean.
        caption = "utilisation"
        if pinned and summary.util is not None:
            auto = summary.auto_budget
            caption += (f" - auto {auto:g}, pinned" if auto is not None
                        else " - pinned")
        self._util_meter.set_caption(caption)

        self._wire_meter.set_value(
            "-" if summary.wire_bytes is None
            else f"{summary.wire_bytes:,} B",
            None if summary.wire_bytes is not None else theme.INK_GHOST)

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


class _ClipDelegate(QStyledItemDelegate):
    """Paints a clip row as a number plus a status, rather than one run
    of text reading "001  stale".

    The rail is the tool's navigation, and its whole job is answering
    "which clips still need work" at a glance. A status word rendered in
    the same ink and size as the clip number makes that a reading task;
    a colour-coded dot and a demoted status caption make it a scan. The
    item's own text() is left intact as the underlying data - only the
    painting changes."""

    STATUS_COLOURS = {
        "stale": theme.PHOSPHOR,     # needs a re-encode
        "tuned": theme.HEADROOM,     # has per-clip settings, up to date
        "default": theme.INK_FAINT,  # riding the kit defaults
    }
    STATUS_ROLE = Qt.UserRole + 1
    ROW_HEIGHT = 30

    def sizeHint(self, option, index):
        return QSize(super().sizeHint(option, index).width(), self.ROW_HEIGHT)

    def paint(self, painter, option, index):
        opt = QStyleOptionViewItem(option)
        self.initStyleOption(opt, index)
        # Let the style (and therefore the stylesheet's ::item rules)
        # draw the row background, hover and selection - then draw the
        # content, with the base text blanked so it is not drawn twice.
        opt.text = ""
        widget = opt.widget
        style = widget.style() if widget is not None else QApplication.style()
        style.drawControl(QStyle.CE_ItemViewItem, opt, painter, widget)

        num3 = index.data(Qt.UserRole) or ""
        status = index.data(self.STATUS_ROLE) or ""
        colour = QColor(self.STATUS_COLOURS.get(status, theme.INK_FAINT))
        selected = bool(opt.state & QStyle.State_Selected)

        rect = option.rect.adjusted(theme.GAP_ROW, 0, -theme.GAP_ROW, 0)
        painter.save()
        painter.setRenderHint(QPainter.Antialiasing, True)

        painter.setPen(Qt.NoPen)
        painter.setBrush(colour)
        painter.drawEllipse(QRect(rect.left(), rect.center().y() - 2, 5, 5))

        painter.setFont(theme.figure_font(10, bold=True))
        painter.setPen(QColor(theme.INK if selected else theme.INK_DIM))
        painter.drawText(rect.adjusted(theme.GAP_PANE + 2, 0, 0, 0),
                         Qt.AlignVCenter | Qt.AlignLeft, str(num3))

        painter.setFont(theme.caption_font())
        painter.setPen(colour)
        painter.drawText(rect, Qt.AlignVCenter | Qt.AlignRight, status)
        painter.restore()


def _rail_caption(text):
    """Small tracked caption naming a pane. Three of these are what stop
    the window reading as three undifferentiated boxes."""
    label = QLabel(text)
    label.setFont(theme.caption_font())
    label.setStyleSheet(f"color: {theme.INK_FAINT}; padding-left: 2px;")
    return label


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
        self._basic_form.setHorizontalSpacing(theme.GAP_PANE)
        self._basic_form.setVerticalSpacing(theme.GAP_ROW)
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
        self._advanced_form.setHorizontalSpacing(theme.GAP_PANE)
        self._advanced_form.setVerticalSpacing(theme.GAP_ROW)
        self._advanced_content.setVisible(False)
        group_layout = QVBoxLayout(self._advanced_group)
        group_layout.addWidget(self._advanced_content)
        self._advanced_group.toggled.connect(self._advanced_content.setVisible)

        # Flags vidtune has no Knob row for, riding through untouched.
        # Monospace because they are literal argv tokens, not prose.
        self._extra_label = QLabel("")
        self._extra_label.setWordWrap(True)
        self._extra_label.setFont(theme.figure_font(8.5))
        self._extra_label.setStyleSheet(
            f"color: {theme.INK_FAINT}; background: {theme.INSET};"
            f"border: 1px solid {theme.EDGE_SOFT};"
            f"border-radius: {theme.RADIUS_CONTROL}px;"
            f"padding: {theme.GAP_ROW}px;")
        self._extra_label.setVisible(False)

        outer = QVBoxLayout(self)
        outer.setContentsMargins(0, 0, theme.GAP_ROW, 0)
        outer.setSpacing(theme.GAP_PANE)
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
            reset_btn.setToolTip("restore this knob to the kit default")
            reset_btn.clicked.connect(
                lambda checked=False, name=knob.name: self._reset(name))
            label = QLabel(knob.name)
            if knob.tooltip:
                label.setToolTip(knob.tooltip)

            row_box = QHBoxLayout()
            row_box.setContentsMargins(0, 0, 0, 0)
            row_box.setSpacing(theme.UNIT)
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

        if knob.kind == "flagstr":
            # Checkbox + a text field enabled only while checked -
            # tri-state value (False/None off, True on-with-default,
            # str on-with-explicit) via ONE row widget: --prefilter is
            # argparse nargs="?" (bare flag = its own conservative
            # const, an explicit value overrides it). The placeholder
            # shows the const so an empty-but-checked box clearly reads
            # as "the default", never as "nothing will happen".
            container = QWidget()
            inner = QHBoxLayout(container)
            inner.setContentsMargins(0, 0, 0, 0)
            inner.setSpacing(theme.UNIT)
            box = QCheckBox()
            edit = QLineEdit()
            edit.setPlaceholderText(
                knob.const if isinstance(knob.const, str) else "")
            edit.setEnabled(False)
            inner.addWidget(box)
            inner.addWidget(edit, 1)

            def _sync_enabled(checked, edit=edit):
                edit.setEnabled(checked)
            box.toggled.connect(_sync_enabled)
            box.stateChanged.connect(self._on_edit)
            edit.textChanged.connect(self._on_edit)

            def getter(box=box, edit=edit):
                if not box.isChecked():
                    return False
                text = edit.text()
                return text if text != "" else True

            def setter(value, box=box, edit=edit):
                box.blockSignals(True)
                edit.blockSignals(True)
                checked = bool(value)   # True or a non-empty str -> checked
                box.setChecked(checked)
                edit.setEnabled(checked)
                edit.setText(value if isinstance(value, str) else "")
                box.blockSignals(False)
                edit.blockSignals(False)

            return container, getter, setter

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
        """A knob that differs from the kit default is the answer to
        "what have I actually changed on this clip", so it gets the
        accent as well as the weight - bold alone, in a rail of fifteen
        rows, is easy to miss."""
        for name, row in self._rows.items():
            deviating = row["getter"]() != self._kit_base.get(name)
            font = row["label"].font()
            font.setBold(deviating)
            row["label"].setFont(font)
            row["label"].setStyleSheet(
                f"color: {theme.ACCENT};" if deviating
                else f"color: {theme.INK_DIM};")
            row["reset_btn"].setVisible(deviating)

    def _reset(self, name):
        row = self._rows[name]
        row["setter"](self._kit_base.get(name))
        self._refresh_deviations()
        self.changed.emit()


class MainWindow(QMainWindow):
    # Initial-geometry constants (owner-requested 2026-08-01: the window
    # used to open needing a manual resize before the settings panel's
    # scroll area stopped showing scrollbars). See _compute_initial_width.
    _CLIP_LIST_WIDTH = 220
    _PREVIEW_WIDTH = 320 * 2 + 40   # 320-wide clip at PreviewPane's 2x default + margins
    _SPLITTER_SLACK = 24            # splitter handles + central layout margins
    _SCROLLBAR_ALLOWANCE = 24       # headroom for a vertical scrollbar once the form is tall
    _MIN_HEIGHT = 700

    def __init__(self, kit_root: Path):
        super().__init__()
        self.kit_root = Path(kit_root)
        self.cfg = parse_config(self.kit_root / "CONFIG.BAT")
        self.cfg_mtime = (self.kit_root / "CONFIG.BAT").stat().st_mtime
        self.stamp = read_generation_stamp(self.kit_root)
        self.clips = list_clips(self.kit_root)
        try:
            self.kit_base = settingsmodel._kit_base(self.cfg)
        except (VidprofileUnsupported, ValueError):
            # Bad VIDASPECT/VIDPROFILE in CONFIG.BAT - _populate_clip_list
            # (called later in __init__) hits this same exception per
            # clip and raises the red banner; this fallback only keeps
            # construction from crashing before that point is reached
            # (a bad VIDASPECT used to kill MainWindow.__init__ with no
            # UI at all under --windowed).
            self.kit_base = {k.name: k.default for k in KNOBS}
            self.kit_base["extra"] = []
        self.session_edits: dict = {}
        self._current_clip = None

        # Session-only budget pins, per-clip segment marks (start_s,
        # dur_s), and "last successful full encode" argv, per clip
        # num3 - all reset when the window closes. self.segments is
        # the persistent store for Preview Segment's marks: previewpane
        # resets the pane's own seg_in/seg_out at the end of every
        # load() (including the preview load a segment run itself
        # triggers), so this is what keeps a marked segment alive
        # across a second Preview Segment click.
        self.pinned_budgets: dict = {}
        self.full_ok: dict = {}
        self.segments: dict = {}
        self._last_source_error = None

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
        self.setStyleSheet(theme.stylesheet())

        self._banner = QLabel("")
        self._banner.setStyleSheet(
            f"background: {theme.FAULT}; color: {theme.INK};"
            f"border-radius: {theme.RADIUS_CONTROL}px;"
            f"padding: {theme.GAP_ROW}px;")
        self._banner.setVisible(False)
        self._banner.setWordWrap(True)

        self.clip_list = QListWidget()
        self.clip_list.setItemDelegate(_ClipDelegate(self.clip_list))
        self.clip_list.setUniformItemSizes(True)
        # The delegate draws the number left and the status hard right
        # inside whatever width the rail has, so there is never anything
        # off to the side to scroll to - the bar Qt sizes from the item
        # text would be a control that does nothing.
        self.clip_list.setHorizontalScrollBarPolicy(Qt.ScrollBarAlwaysOff)

        self.settings_panel = SettingsPanel()
        self.settings_scroll = QScrollArea()
        self.settings_scroll.setWidgetResizable(True)
        self.settings_scroll.setWidget(self.settings_panel)

        self.preview = PreviewPane()

        left_pane = QWidget()
        left_layout = QVBoxLayout(left_pane)
        left_layout.setContentsMargins(0, 0, 0, 0)
        left_layout.setSpacing(theme.GAP_ROW)
        left_layout.addWidget(_rail_caption("clips"))
        left_layout.addWidget(self._banner)
        left_layout.addWidget(self.clip_list)

        settings_pane = QWidget()
        settings_layout = QVBoxLayout(settings_pane)
        settings_layout.setContentsMargins(0, 0, 0, 0)
        settings_layout.setSpacing(theme.GAP_ROW)
        settings_layout.addWidget(_rail_caption("encode settings"))
        settings_layout.addWidget(self.settings_scroll)

        self._splitter = QSplitter(Qt.Horizontal)
        self._splitter.addWidget(left_pane)
        self._splitter.addWidget(self.preview)
        self._splitter.addWidget(settings_pane)
        self._splitter.setChildrenCollapsible(False)
        # 16/60/24 rather than the original 20/50/30. The picture is what
        # the tool exists to judge, so it takes the majority of the width
        # outright; the settings rail is an instrument panel serving it,
        # not its peer. Each pane is still floored at its own minimum by
        # _initial_pane_widths, so the narrower rail can never squeeze the
        # form back into showing scrollbars.
        self._splitter.setStretchFactor(0, 16)
        self._splitter.setStretchFactor(1, 60)
        self._splitter.setStretchFactor(2, 24)
        # Real sizes are set at the end of __init__ by
        # _apply_initial_geometry(), once the settings panel has its real
        # (post clip-selection) sizeHint to work from; this is just a
        # placeholder so the splitter has something sane before then.
        self._splitter.setSizes([200, 500, 300])

        self.preview_button = QPushButton("Preview Segment")
        self.encode_button = QPushButton("Encode Full")
        # Accept is the one action that commits - it writes VIDOPTS_NNN
        # into CONFIG.BAT and copies the encode into place. Everything
        # else on this row is reversible experimentation, so Accept is
        # the single primary and the rest stay quiet.
        self.accept_button = QPushButton("Accept")
        self.accept_button.setProperty("primary", True)
        self.accept_button.setEnabled(False)
        self.encode_all_button = QPushButton("Encode All Stale")

        actions_row = QHBoxLayout()
        actions_row.setSpacing(theme.GAP_ROW)
        actions_row.addWidget(self.preview_button)
        actions_row.addWidget(self.encode_button)
        actions_row.addSpacing(theme.GAP_ROW)
        actions_row.addWidget(self.accept_button)
        actions_row.addStretch(1)
        # A bulk action over every stale clip, not part of tuning the
        # clip in front of you - held apart at the far end of the row.
        actions_row.addWidget(self.encode_all_button)

        self.metrics_bar = MetricsBar()
        self.metrics_bar.set_preview(self.preview)

        central = QWidget()
        central_layout = QVBoxLayout(central)
        central_layout.setContentsMargins(theme.GAP_PANE, theme.GAP_PANE,
                                          theme.GAP_PANE, theme.GAP_ROW)
        central_layout.setSpacing(theme.GAP_ZONE)
        central_layout.addWidget(self._splitter, 1)
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
        self.preview.cleared.connect(self._on_pane_cleared)

        self.clip_list.currentItemChanged.connect(self._on_current_item_changed)
        self._populate_clip_list()
        if self.clip_list.count():
            self.clip_list.setCurrentRow(0)   # populates settings_panel before sizing below

        self._apply_initial_geometry()

    def _initial_pane_widths(self):
        """(clip_list, preview, settings) floor widths for the default
        layout. Preview and settings are each the LARGER of a nominal
        target and the pane's own minimumSizeHint - PreviewPane's
        transport row (Play/Stop/</>/Loop/Set In/Set Out/Clear/segment
        readout/2x) has a real minimum width of its own (driven by the
        host style's button metrics, not just the 320-wide-at-2x image),
        and QSplitter.setSizes() silently overrides an under-sized
        request to respect a child's minimumSizeHint - which is exactly
        how a fixed 640px guess for the preview pane used to starve the
        settings pane back down to its scrollbar-showing width."""
        panel_width = max(
            self.settings_panel.sizeHint().width()
            + self.settings_scroll.frameWidth() * 2 + self._SCROLLBAR_ALLOWANCE,
            self.settings_scroll.minimumSizeHint().width())
        preview_width = max(self._PREVIEW_WIDTH,
                            self.preview.minimumSizeHint().width())
        return self._CLIP_LIST_WIDTH, preview_width, panel_width

    def _compute_initial_width(self):
        """Uncapped width the default layout needs to avoid the settings
        panel's scroll area showing a horizontal scrollbar. Split out
        from _apply_initial_geometry so it can be checked directly
        against the screen-capped result (real screen size varies, esp.
        under test)."""
        clip_width, preview_width, panel_width = self._initial_pane_widths()
        return clip_width + preview_width + panel_width + self._SPLITTER_SLACK

    def _apply_initial_geometry(self):
        """Sizes the window - and the splitter's initial pane widths - so
        the default layout needs no manual resize on launch. Capped to
        the primary screen's available geometry so this never opens
        larger than the screen; the 20/50/30 clip-list/preview/settings
        split from the original design is kept as the intent, but each
        pane is floored at its own minimum requirement (see
        _initial_pane_widths)."""
        clip_width, preview_width, panel_width = self._initial_pane_widths()
        total_width = clip_width + preview_width + panel_width + self._SPLITTER_SLACK
        total_height = max(self.settings_panel.sizeHint().height() + 160,
                           self._MIN_HEIGHT)

        screen = QGuiApplication.primaryScreen()
        if screen is not None:
            avail = screen.availableGeometry()
            total_width = min(total_width, avail.width())
            total_height = min(total_height, avail.height())

        self.resize(total_width, total_height)
        # QSplitter.setSizes() distributes against the splitter's OWN
        # current width - before the window has ever been shown, a top-
        # level widget's internal QMainWindowLayout (which sizes the
        # central widget) and the central widget's own layout (which
        # sizes the splitter) have not run yet, so both still reflect
        # their pre-resize state despite the resize() just issued above.
        # Explicitly activating each layout in turn (invalidating the
        # central layout first, since a plain activate() is a no-op
        # unless the layout is already marked dirty) is what makes the
        # splitter's actual width - and therefore setSizes() below -
        # correct instead of being computed against a stale, much
        # smaller size.
        self.layout().activate()
        central_layout = self.centralWidget().layout()
        central_layout.invalidate()
        central_layout.activate()
        self._splitter.setSizes([clip_width, preview_width, panel_width])

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
                # text() stays the plain "001  stale" data string; the
                # two roles are what _ClipDelegate actually paints from.
                item = QListWidgetItem(f"{clip.num3}  {status}")
                item.setData(Qt.UserRole, clip.num3)
                item.setData(_ClipDelegate.STATUS_ROLE, status)
                self.clip_list.addItem(item)
        except (VidprofileUnsupported, ValueError) as exc:
            # ValueError is _shape_args rejecting a malformed VIDASPECT
            # (e.g. "wide") - previously uncaught here, so a config typo
            # took MainWindow.__init__ down with no UI under --windowed.
            self.clip_list.clear()
            self._banner.setText(str(exc))
            self._banner.setVisible(True)
            self._set_actions_enabled(False)

    def _on_current_item_changed(self, current, previous):
        if current is None:
            return
        self.select_clip(current.data(Qt.UserRole))

    def _guarded(self, fn, *args):
        """Runs fn(*args), catching a bad-config error - VidprofileUnsupported
        (VIDPROFILE set without VIDASPECT) or ValueError (a malformed
        VIDASPECT such as "wide") raised anywhere along the
        build_arg_vector/_shape_args chain. Surfaces it in the same red
        banner _populate_clip_list uses and disables the action
        buttons, instead of letting it propagate out of a signal
        handler and take the window down with no UI. Returns fn(*args),
        or None on error."""
        try:
            return fn(*args)
        except (VidprofileUnsupported, ValueError) as exc:
            self._banner.setText(str(exc))
            self._banner.setVisible(True)
            self._set_actions_enabled(False)
            return None

    def select_clip(self, num3: str):
        if self._current_clip is not None:
            self.session_edits[self._current_clip] = self.settings_panel.get_settings()
        if num3 in self.session_edits:
            settings = self.session_edits[num3]
        else:
            settings = self._guarded(effective_settings, self.cfg, num3)
            if settings is None:
                settings = dict(self.kit_base)
        self.settings_panel.set_settings(settings, self.kit_base)
        self._current_clip = num3
        self._update_accept_enabled()
        # A "budget provisional" status label, the metrics figures, and
        # the segment markers all belong to the clip that was open when
        # they were set - none of them may carry over to a newly-
        # selected clip: a stray marker would silently segment-limit an
        # unrelated encode, and stale metrics/status would misattribute
        # a job that hasn't run for this clip yet.
        self.metrics_bar.set_status("")
        self.metrics_bar.clear(num3)
        self.preview.clear()

        clip = self._clip_by_num3(num3)
        if clip is None:
            return
        state = self._guarded(clip_state, clip, self.cfg, self.stamp)
        if state is None:
            self.preview.clear_to_empty("clip state unavailable - see banner above")
            return
        _tuned, stale = state
        if clip.vid.is_file() and not stale:
            dims = self._guarded(self._resolve_dims, settings)
            width = dims[0] if dims is not None else 320
            self.preview.load(clip.vid, None, column_major=(width == 320))
        else:
            # Owner-requested (2026-08-01): a clip with no fresh .vid
            # used to leave the pane on the empty hint with nothing to
            # scrub - step/Set In/Set Out had no frames to act on. Load
            # the clip's SOURCE frames instead (capped, off the GUI
            # thread) so segment selection is possible before any encode
            # has run; _load_source_preview falls back to the same empty
            # hint itself if extraction isn't currently possible (no
            # source .mp4, no ffmpeg).
            self._load_source_preview(num3, clip, settings)

    def _load_source_preview(self, num3, clip, settings):
        """Loads a not-yet-encoded clip's SOURCE frames into the pane
        (encoded=None) so the user can scrub the timeline and mark
        Set In/Set Out before ever running an encode. Extraction uses
        the clip's EFFECTIVE settings - shape width/height, target fps,
        retime, clip-level trim - resolved by _resolve_extraction_params
        the SAME way _extract_matching_source resolves them post-encode,
        so a marker set here already lines up with the eventual encode's
        timeline (target-fps extraction is what makes that true - a
        raw-source-fps preview would not). Runs off the GUI thread via
        PreviewPane.load_source, since ffmpeg extraction is not fast;
        duration capped at SOURCE_PREVIEW_CAP_SECONDS (see its module
        docstring)."""
        params = self._guarded(self._resolve_extraction_params, num3)
        if params is None:
            self.preview.clear_to_empty(
                "no fresh preview yet - run Preview Segment or Encode Full "
                "to generate one")
            return
        ffmpeg, mp4, width, height, fps, retime = params
        column_major = (width == 320)
        start, duration, capped = self._source_preview_extract_args(settings)

        hint = SOURCE_PREVIEW_HINT
        if capped:
            hint += f" (showing first {int(SOURCE_PREVIEW_CAP_SECONDS)}s of source)"

        # extract_source is a pure function (ffmpeg subprocess + numpy) -
        # no Qt widget access - so this closure is safe to actually run
        # on PreviewPane's worker thread; everything it needs is already
        # a plain value captured here on the GUI thread. Referenced
        # unqualified (module-level `extract_source`, imported above) so
        # tests can monkeypatch vt_mainwindow.extract_source the same
        # way test_extract_matching_source_failure_logs_to_pane_not_silence
        # already does for the post-encode path.
        extract_fn = lambda: extract_source(ffmpeg, mp4, width, height, fps,
                                            retime, start, duration)
        self.preview.load_source(extract_fn, fps, column_major, hint=hint)

    def _source_preview_extract_args(self, settings):
        """(start, duration, capped) seconds for the un-encoded source-
        preview path, from the clip's EFFECTIVE settings (the clip-level
        start/duration Knobs) - duration capped at
        SOURCE_PREVIEW_CAP_SECONDS. capped is True when the cap actually
        shortened what would otherwise have been extracted (no
        clip-level duration set, or one longer than the cap), so the
        caller can show a "showing first Ns" note; False when the
        clip's own --duration setting already fits inside the cap (the
        full set segment was extracted, nothing was truncated)."""
        start = to_seconds(settings.get("start"))
        dur_setting = settings.get("duration")
        clip_duration = to_seconds(dur_setting) if dur_setting is not None else None
        if clip_duration is not None and clip_duration <= SOURCE_PREVIEW_CAP_SECONDS:
            return start, clip_duration, False
        return start, SOURCE_PREVIEW_CAP_SECONDS, True

    def _on_pane_cleared(self):
        """PreviewPane.cleared fires only from a user-initiated Clear
        button click (see its docstring in previewpane.py) - never from
        select_clip's own programmatic self.preview.clear() call. Pop
        the current clip's captured segment so a cleared segment does
        not silently re-apply on the next Preview Segment (it otherwise
        survives in self.segments even though the pane's own seg_in/
        seg_out are reset - see preview_argv's docstring)."""
        if self._current_clip is not None:
            self.segments.pop(self._current_clip, None)

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
        """Builds the encoder argv for a Preview Segment run. The
        segment is captured into self.segments[num3] (seconds, per
        clip) as a side effect here, mirroring self.pinned_budgets:
        previewpane.set_frames resets the pane's own live seg_in/
        seg_out at the end of every load() - including the very
        preview load a segment run is about to trigger - so a second
        Preview Segment click with no fresh marks on the pane would
        otherwise silently fall back to a full-clip encode. The stored
        value is what actually drives the argv; live pane markers, when
        present, both drive it AND refresh (overwrite) the stored
        value - a re-mark replaces the old segment."""
        settings = self._current_settings(num3)
        argv = self._argv_for_settings(settings)
        fps = float(settings.get("fps") or 25)
        live = self.preview.segment_times(fps)
        if live is not None:
            self.segments[num3] = live
        seg = self.segments.get(num3)
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
        if num3 is None:
            self.accept_button.setEnabled(False)
            return
        argv = self._guarded(self.full_argv, num3)
        enabled = argv is not None and self.full_ok.get(num3) == argv
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
        argv = self._guarded(self.preview_argv, num3)
        if argv is None:
            return
        output = self.scratch_dir / f"preview_{num3}.vid"
        self._start_job("preview", num3, clip, output, argv)

    def on_encode_full(self):
        num3 = self._current_clip
        clip = self._clip_by_num3(num3) if num3 is not None else None
        if clip is None or self._job is not None:
            return
        argv = self._guarded(self.full_argv, num3)
        if argv is None:
            return
        output = self.scratch_dir / f"full_{num3}.vid"
        self._start_job("full", num3, clip, output, argv)

    def on_encode_all_stale(self):
        if self._job is not None:
            return
        stale = self._guarded(self._stale_clips)
        if stale is None:
            return
        self._all_queue = stale
        self._all_cancelled = False
        self._advance_all_queue()

    def _stale_clips(self):
        return [c for c in self.clips if clip_state(c, self.cfg, self.stamp)[1]]

    def _advance_all_queue(self):
        if self._all_cancelled or not self._all_queue:
            self._all_queue = []
            self._set_actions_enabled(True)
            return
        clip = self._all_queue.pop(0)
        argv = self._guarded(settingsmodel.build_arg_vector, self.cfg, clip.num3)
        if argv is None:
            self._all_queue = []
            return
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
        if num3 is None:
            return
        current_full_argv = self._guarded(self.full_argv, num3)
        if current_full_argv is None or self.full_ok.get(num3) != current_full_argv:
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
        dev = self._guarded(settingsmodel.deviations, settings, self.cfg)
        if dev is None:
            return
        opts = " ".join(dev)
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
        saved_argv = self._guarded(settingsmodel.build_arg_vector, self.cfg, num3)
        if saved_argv is None:
            return
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
        self.metrics_bar.update_from(summary, pinned, num3)
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
        self.metrics_bar.update_from(summary, num3 in self.pinned_budgets, num3)
        # A full encode always derives the budget from the whole clip -
        # never provisional - so any stale "provisional" label from an
        # earlier segment preview must not linger.
        self.metrics_bar.set_status("")
        self._load_preview(num3, output, argv)
        self._update_accept_enabled()

    def _on_all_success(self, num3, argv, summary):
        clip = self._clip_by_num3(num3)
        write_sidecar(clip.sidecar, self.stamp or "", argv)
        self.metrics_bar.update_from(summary, num3 in self.pinned_budgets, num3)
        self.metrics_bar.set_status("")
        self._populate_clip_list()

    # -- preview/source loading ----------------------------------------------

    def _load_preview(self, num3, vid_path, argv):
        source = self._extract_matching_source(num3, argv)
        self.preview.load(vid_path, source, column_major=False)
        if self._last_source_error:
            self.preview.show_error(
                f"source comparison unavailable: {self._last_source_error}")

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

    def _resolve_extraction_params(self, num3):
        """Resolves (ffmpeg, mp4, width, height, fps, retime) from the
        clip's EFFECTIVE settings - GUI-thread only, since
        _current_settings()/self.settings_panel touch live Qt widgets.
        Returns None if extraction isn't currently possible (no source
        .mp4, no ffmpeg on this machine) - not an error, just nothing to
        do. Shared by _extract_matching_source (post-encode Flicker/
        Heatmap comparison) and _load_source_preview (the un-encoded
        source-preview path) so both resolve dims/fps/retime the exact
        same way - only start/duration differ between the two callers."""
        clip = self._clip_by_num3(num3)
        if clip is None or not clip.mp4.is_file():
            return None
        if self.ffmpeg is None or not Path(self.ffmpeg).is_file():
            return None
        settings = self._current_settings(num3)
        width, height = self._resolve_dims(settings)
        fps = float(settings.get("fps") or 25)
        retime = settings.get("retime") or "blend"
        return str(self.ffmpeg), clip.mp4, width, height, fps, retime

    def _extract_matching_source(self, num3, argv):
        """Best-effort: source frames shaped/retimed/trimmed to match
        the encode that just ran, for Flicker/Heatmap comparison. Runs
        ffmpeg synchronously on the GUI thread (busy cursor) - a known
        polish gap, not a correctness one: any failure here drops back
        to an encoded-only preview, which PreviewPane already supports,
        but the failure is recorded in self._last_source_error and
        surfaced by the caller (_load_preview) into the pane's error
        label - an HH:MM:SS --start used to fail here silently with no
        message at all, back when this parsed with float()."""
        self._last_source_error = None
        try:
            params = self._resolve_extraction_params(num3)
            if params is None:
                return None
            ffmpeg, mp4, width, height, fps, retime = params
            start, duration = _parse_start_duration(argv)
            QApplication.setOverrideCursor(Qt.WaitCursor)
            try:
                return extract_source(ffmpeg, mp4, width, height,
                                      fps, retime, start, duration)
            finally:
                QApplication.restoreOverrideCursor()
        except Exception as exc:
            self._last_source_error = str(exc)
            return None
