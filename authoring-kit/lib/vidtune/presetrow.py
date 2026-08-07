"""Qt surface for the presets: the route menu and the banding ladder.

The logic lives in presets.py; this file is only how it is shown.

Two shapes, because the underlying objects are two different kinds of
thing (see presets.py):

  RouteMenuButton  a MOMENTARY menu. Routes are mutually exclusive, but
                   nothing here ever claims a route is "active" - the
                   user is free to edit any knob afterwards, and a
                   control showing a persistent current preset would be
                   lying the moment they did. Pressing it stamps values
                   and the menu is gone.

  LadderPanel      a workflow, collapsed by default, whose step states
                   are DERIVED from the current knobs on every refresh
                   rather than stored.

Each route states what it will change BEFORE it is chosen, which is what
keeps "shape is the user's call" honest: a route that would overwrite an
explicitly-set shape shows that as one of its own delta lines.
"""
from PySide6.QtCore import QSize, Qt, Signal
from PySide6.QtWidgets import (
    QHBoxLayout,
    QLabel,
    QMenu,
    QPushButton,
    QSizePolicy,
    QVBoxLayout,
    QWidget,
    QWidgetAction,
)

from . import presets, theme

CHOOSE_TEXT = "choose a route..."


class _WrapLabel(QLabel):
    """A word-wrapped QLabel that actually reserves the height it needs.

    Qt only consults heightForWidth when every widget in the chain opts
    into it, and QScrollArea - which is what the settings rail is - does
    not. A wrapped label inside it therefore reports a single line's
    height, and its second and third lines clip into whatever sits
    below. Syncing minimumHeight to the wrapped height on every resize
    is the fix that does not depend on that chain cooperating.
    """

    def __init__(self, text="", parent=None):
        super().__init__(text, parent)
        self.setWordWrap(True)
        # Top-aligned, not Qt's default vertical centring: the reserved
        # height is a ceiling for the widest case, so any surplus must
        # fall BELOW the text. Centred, the surplus splits above and
        # below and a step's own detail drifts away from its title and
        # towards the next step's - which reads as belonging to the
        # wrong rung.
        self.setAlignment(Qt.AlignTop | Qt.AlignLeft)

    def setText(self, text):
        super().setText(text)
        self._sync_height()

    def minimumSizeHint(self):
        """Answer with the WRAPPED height straight away.

        _sync_height alone is not enough: resizeEvent is posted, not
        delivered synchronously, so a layout pass that runs before the
        event loop gets a turn would still be told one line. Reporting
        it here means the layout is right on the first pass and the
        resize sync is only there to follow later width changes."""
        hint = super().minimumSizeHint()
        if self.width() > 0:
            wrapped = self.heightForWidth(self.width())
            if wrapped > 0:
                return QSize(hint.width(), max(hint.height(), wrapped))
        return hint

    def resizeEvent(self, event):
        super().resizeEvent(event)
        self._sync_height()

    def _sync_height(self):
        if self.width() <= 0:
            return
        needed = self.heightForWidth(self.width())
        if needed > 0 and needed != self.minimumHeight():
            self.setMinimumHeight(needed)


class _RouteItem(QWidget):
    """One route inside the menu: its label, and under it the deltas
    applying it would produce against the current settings.

    A QWidgetAction rather than a plain QAction because a QAction is one
    run of text in one colour, which would give the label and its deltas
    equal billing. QMenu still owns dismissal, Escape and positioning -
    only the item's content is custom."""

    clicked = Signal(str)          # route key

    def __init__(self, route, delta_lines, indent=False, top_gap=False,
                 parent=None):
        super().__init__(parent)
        self._key = route.key
        self.setCursor(Qt.PointingHandCursor)

        label = QLabel(route.label)
        label.setFont(theme.ui_font(9.5, bold=not indent))
        label.setStyleSheet(
            f"color: {theme.INK_DIM if indent else theme.INK}; background: transparent;")

        deltas = QLabel("   ".join(delta_lines))
        deltas.setFont(theme.figure_font(8.5))
        deltas.setStyleSheet(
            f"color: {theme.INK_FAINT}; background: transparent;")

        box = QVBoxLayout(self)
        left = theme.GAP_ZONE + theme.GAP_PANE if indent else theme.GAP_PANE
        # A route and its framing variant are one decision, so they sit
        # tight together; the air goes BETWEEN routes instead.
        box.setContentsMargins(left, theme.GAP_PANE if top_gap else theme.UNIT + 1,
                               theme.GAP_PANE, theme.UNIT + 1)
        box.setSpacing(1)
        box.addWidget(label)
        box.addWidget(deltas)
        self.setAutoFillBackground(True)
        self._paint(False)

    def _paint(self, hover):
        self.setStyleSheet(
            f"_RouteItem {{ background: {theme.RAISED if hover else 'transparent'}; }}")

    def enterEvent(self, event):
        self._paint(True)
        super().enterEvent(event)

    def leaveEvent(self, event):
        self._paint(False)
        super().leaveEvent(event)

    def mouseReleaseEvent(self, event):
        if event.button() == Qt.LeftButton and self.rect().contains(
                event.position().toPoint()):
            self.clicked.emit(self._key)
        super().mouseReleaseEvent(event)


class RouteMenuButton(QPushButton):
    """Opens the route menu. `context()` must return the live
    (settings, kit_base) pair - the menu is rebuilt on EVERY open,
    because every delta line is relative to whatever the panel holds
    right now."""

    route_chosen = Signal(str)

    def __init__(self, context, parent=None):
        super().__init__(CHOOSE_TEXT, parent)
        self._context = context
        self.setToolTip(
            "apply a route from the Video page of the manual - resets the "
            "route knobs to kit defaults first, leaving prefilter and trim "
            "alone")
        self.setSizePolicy(QSizePolicy.Expanding, QSizePolicy.Fixed)
        # Left-aligned, because it spans the full value column: centred
        # text on a control this wide reads as a big action button
        # rather than as something that opens a list. The trailing
        # ellipsis in CHOOSE_TEXT is the rest of that signal.
        self.setStyleSheet(
            f"text-align: left; padding-left: {theme.GAP_ROW}px;")
        self.clicked.connect(self._open)

    def _open(self):
        settings, kit_base = self._context()
        menu = QMenu(self)
        menu.setStyleSheet(f"QMenu {{ background: {theme.PANEL}; "
                           f"border: 1px solid {theme.EDGE_LIT}; padding: "
                           f"{theme.UNIT}px; }}")
        for i, route in enumerate(presets.ROUTES):
            self._add(menu, route, settings, kit_base, indent=False,
                      top_gap=i > 0)
            if route.variant is not None:
                self._add(menu, route.variant, settings, kit_base, indent=True)
        menu.exec(self.mapToGlobal(self.rect().bottomLeft()))

    def _add(self, menu, route, settings, kit_base, indent, top_gap=False):
        lines = presets.format_deltas(
            presets.route_deltas(settings, kit_base, route))
        item = _RouteItem(route, lines, indent=indent, top_gap=top_gap)
        item.setToolTip(route.blurb)
        item.clicked.connect(self.route_chosen.emit)
        item.clicked.connect(menu.close)
        action = QWidgetAction(menu)
        action.setDefaultWidget(item)
        menu.addAction(action)


class _StepRow(QWidget):
    """One rung: number, what it is, what it costs, and the action."""

    apply_values = Signal(object)
    route_chosen = Signal(str)

    def __init__(self, step, blocked, parent=None):
        super().__init__(parent)

        number = QLabel(str(step.n))
        number.setFont(theme.figure_font(9, bold=True))
        number.setStyleSheet(
            f"color: {theme.HEADROOM if step.done else theme.INK_FAINT};")
        number.setFixedWidth(theme.GAP_PANE)

        label = QLabel(step.label)
        label.setFont(theme.ui_font(9.5, bold=True))
        label.setStyleSheet(
            f"color: {theme.INK_FAINT if step.done else theme.INK};")
        detail = _WrapLabel(step.detail)
        detail.setFont(theme.ui_font(8.5))
        detail.setStyleSheet(f"color: {theme.INK_FAINT};")

        text = QVBoxLayout()
        text.setContentsMargins(0, 0, 0, 0)
        text.setSpacing(1)
        text.addWidget(label)
        text.addWidget(detail)

        row = QHBoxLayout(self)
        row.setContentsMargins(0, theme.UNIT, 0, theme.UNIT)
        row.setSpacing(theme.GAP_ROW)
        row.addWidget(number, 0, Qt.AlignTop)
        row.addLayout(text, 1)

        for button in self._actions(step, blocked):
            row.addWidget(button, 0, Qt.AlignTop)

    def _actions(self, step, blocked):
        # Step 6 is advice with no setting behind it, and a step already
        # satisfied by the current knobs says so instead of offering to
        # set it again.
        if step.done:
            chip = QLabel("done")
            chip.setFont(theme.caption_font())
            chip.setStyleSheet(f"color: {theme.HEADROOM};")
            return [chip]
        if step.reason:
            note = QLabel(step.reason)
            note.setFont(theme.caption_font())
            note.setStyleSheet(f"color: {theme.INK_GHOST};")
            return [note]

        out = []
        if step.routes:
            # Step 5 is "switch to preset 2 OR 3" - a real choice between
            # picture size and motion rate, so both are offered rather
            # than one being picked on the user's behalf.
            for key in step.routes:
                route = presets.route_by_key(key)
                button = QPushButton(route.label)
                button.setEnabled(not blocked)
                button.clicked.connect(
                    lambda _=False, k=key: self.route_chosen.emit(k))
                out.append(button)
        elif step.values:
            button = QPushButton(step.action_label)
            button.setEnabled(not blocked)
            button.clicked.connect(
                lambda _=False, v=dict(step.values): self.apply_values.emit(v))
            out.append(button)
        return out


class LadderPanel(QWidget):
    """Preset 6, the anti-banding ladder. `get_settings()` supplies the
    live panel values; refresh() re-derives every step from them."""

    apply_values = Signal(object)
    route_chosen = Signal(str)

    def __init__(self, get_settings, parent=None):
        super().__init__(parent)
        self._get_settings = get_settings

        self._note = _WrapLabel("")
        self._note.setFont(theme.ui_font(8.5))
        self._note.setStyleSheet(
            f"color: {theme.PHOSPHOR}; background: {theme.INSET};"
            f"border: 1px solid {theme.EDGE_SOFT};"
            f"border-radius: {theme.RADIUS_CONTROL}px;"
            f"padding: {theme.GAP_ROW}px;")
        # Hug the text. A wrapped QLabel with the default Preferred
        # vertical policy soaks up whatever spare height the layout has,
        # which turned a two-line note into a tall empty panel.
        note_policy = self._note.sizePolicy()
        note_policy.setVerticalPolicy(QSizePolicy.Minimum)
        note_policy.setHeightForWidth(True)
        self._note.setSizePolicy(note_policy)
        self._note.setVisible(False)

        self._rows = QVBoxLayout()
        self._rows.setContentsMargins(0, 0, 0, 0)
        self._rows.setSpacing(0)

        outer = QVBoxLayout(self)
        outer.setContentsMargins(0, 0, 0, 0)
        outer.setSpacing(theme.GAP_ROW)
        outer.addWidget(self._note)
        outer.addLayout(self._rows)
        self.refresh()

    def refresh(self):
        while self._rows.count():
            item = self._rows.takeAt(0)
            widget = item.widget()
            if widget is not None:
                widget.deleteLater()

        settings = self._get_settings()
        blocked = presets.ladder_blocked_reason(settings)
        self._note.setText(blocked)
        self._note.setVisible(bool(blocked))

        for step in presets.ladder_steps(settings):
            row = _StepRow(step, bool(blocked))
            row.apply_values.connect(self.apply_values.emit)
            row.route_chosen.connect(self.route_chosen.emit)
            self._rows.addWidget(row)
