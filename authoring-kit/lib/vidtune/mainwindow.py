"""Main window shell: clip list, preview placeholder, settings panel.

Three-pane Studio layout (owner-approved wireframe): clip list (~20%),
preview placeholder (~50%), settings panel in a scroll area (~30%),
with a bottom metrics strip and a status bar. The preview pane is a
plain placeholder until Task 9 wires the decode/heatmap views from
preview.py.
"""
from pathlib import Path

from PySide6.QtCore import Qt, Signal
from PySide6.QtGui import QDoubleValidator
from PySide6.QtWidgets import (
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
    QPushButton,
    QScrollArea,
    QSplitter,
    QVBoxLayout,
    QWidget,
)

from . import settingsmodel
from .kitmodel import clip_state, list_clips, parse_config, read_generation_stamp
from .settingsmodel import KNOBS, SHAPE_PRESETS, VidprofileUnsupported, effective_settings


class MetricsBar(QWidget):
    """Bottom strip; placeholder until real metrics are wired in a later
    task."""

    def __init__(self, parent=None):
        super().__init__(parent)
        layout = QHBoxLayout(self)
        layout.setContentsMargins(4, 2, 4, 2)
        layout.addWidget(QLabel("metrics"))


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
        self._advanced_form = QFormLayout()
        self._advanced_group.setLayout(self._advanced_form)

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
            edit.setValidator(QDoubleValidator())
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
        self.stamp = read_generation_stamp(self.kit_root)
        self.clips = list_clips(self.kit_root)
        self.kit_base = settingsmodel._kit_base(self.cfg)
        self.session_edits: dict = {}
        self._current_clip = None

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

        preview_pane = QWidget()
        preview_layout = QVBoxLayout(preview_pane)
        preview_layout.addWidget(QLabel("preview"))

        left_pane = QWidget()
        left_layout = QVBoxLayout(left_pane)
        left_layout.setContentsMargins(0, 0, 0, 0)
        left_layout.addWidget(self._banner)
        left_layout.addWidget(self.clip_list)

        splitter = QSplitter(Qt.Horizontal)
        splitter.addWidget(left_pane)
        splitter.addWidget(preview_pane)
        splitter.addWidget(settings_scroll)
        splitter.setStretchFactor(0, 20)
        splitter.setStretchFactor(1, 50)
        splitter.setStretchFactor(2, 30)
        splitter.setSizes([200, 500, 300])

        self.metrics_bar = MetricsBar()

        central = QWidget()
        central_layout = QVBoxLayout(central)
        central_layout.addWidget(splitter)
        central_layout.addWidget(self.metrics_bar)
        self.setCentralWidget(central)

        if self.stamp is None:
            self.statusBar().addPermanentWidget(QLabel(
                "lib/video.ps1 stamp not found - staleness tracking unreliable"))

        self.clip_list.currentItemChanged.connect(self._on_current_item_changed)
        self._populate_clip_list()
        if self.clip_list.count():
            self.clip_list.setCurrentRow(0)

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
