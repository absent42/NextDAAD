"""WireTrace: per-frame wire cost against the per-frame cap.

The thing a kit author is actually fighting when tuning a clip is the
wire budget - how many bytes each frame costs the player to fetch - and
until now that whole struggle was four dashes in a status strip plus a
button labelled "go" that jumped to the worst burst. This is that data
drawn on the clip's own timeline: cost per frame, the cap as a hard line
across it, and the frames that breach it lit up where they happen.

It doubles as navigation. The strip shares its x-axis with the scrub
slider directly beneath it (both inset by half a slider handle), so a
spike is not just a reading - it is a place, and clicking it goes there.

Costs come from the decoder, not the encoder's report: nxv2dec already
yields each frame's block-rounded payload length while walking the file
(see preview.decode_vid), which is exactly what the player fetches. The
BuildReport only carries whole-clip aggregates.
"""
from PySide6.QtCore import QRectF, Qt, Signal
from PySide6.QtGui import QColor, QPainter, QPen
from PySide6.QtWidgets import QSizePolicy, QWidget

from . import theme

PLOT_HEIGHT = 40
TICK_LANE = 6          # keyframe-span marks live below the plot
HEIGHT = PLOT_HEIGHT + TICK_LANE

# A frame at or over the cap cannot be fetched in time; one in the top
# band is close enough that a small settings change will push it over.
# Headroom so an overrun is visibly ABOVE the cap line rather than
# clipped flat against the top of the widget - the overrun is the whole
# point of drawing this.
CAP_HEADROOM = 1.35

# The x-axis is shared with QSlider, whose groove is inset by half a
# handle at each end (see theme.SLIDER_HANDLE_WIDTH).
INSET = theme.SLIDER_HANDLE_WIDTH // 2

OP_KFLIP = 0x20
OP_KSTART = 0x28


class WireTrace(QWidget):
    """Per-frame wire cost with the cap drawn across it. Click or drag to
    seek; emits seek_requested(frame)."""

    seek_requested = Signal(int)

    def __init__(self, parent=None):
        super().__init__(parent)
        self._costs = []
        self._terms = []
        self._cap = None
        self._playhead = 0
        self._seg_in = None
        self._seg_out = None
        self._empty_text = ""
        self.setFixedHeight(HEIGHT)
        self.setSizePolicy(QSizePolicy.Expanding, QSizePolicy.Fixed)
        self.setMouseTracking(True)
        # The pane owns keyboard focus (Space = play/flicker); a click
        # here must seek without stealing it, same rule as every other
        # control in the transport.
        self.setFocusPolicy(Qt.NoFocus)

    # -- data ------------------------------------------------------------

    def set_trace(self, costs, terms=None, cap=None):
        self._costs = list(costs or [])
        self._terms = list(terms or [])
        self._cap = cap if cap else None
        self.update()

    def set_empty_text(self, text):
        """Shown centred when there is nothing to plot - a clip that has
        not been encoded yet has no wire data, and saying so beats an
        empty well the user has to interpret."""
        self._empty_text = text or ""
        self.update()

    def clear(self):
        self._costs = []
        self._terms = []
        self._cap = None
        self._playhead = 0
        self._seg_in = None
        self._seg_out = None
        self.update()

    def set_playhead(self, index):
        self._playhead = int(index)
        self.update()

    def set_segment(self, seg_in, seg_out):
        self._seg_in = seg_in
        self._seg_out = seg_out
        self.update()

    def has_data(self):
        return bool(self._costs)

    def peak_frame(self):
        """Index of the most expensive frame, or None. This is what the
        old "go to worst burst" button pointed at - kept as a method so
        the burst jump still has a target when the encoder's report does
        not name one."""
        if not self._costs:
            return None
        return max(range(len(self._costs)), key=self._costs.__getitem__)

    def over_cap_count(self):
        if not self._costs or not self._cap:
            return 0
        return sum(1 for c in self._costs if c >= self._cap)

    # -- geometry --------------------------------------------------------

    def _span(self):
        return max(1, self.width() - 2 * INSET)

    def _x_for_frame(self, index):
        n = len(self._costs)
        if n <= 1:
            return INSET
        frac = min(max(index / (n - 1), 0.0), 1.0)
        return INSET + frac * self._span()

    def _frame_for_x(self, x):
        n = len(self._costs)
        if n <= 1:
            return 0
        frac = (x - INSET) / self._span()
        return int(round(min(max(frac, 0.0), 1.0) * (n - 1)))

    def _top_value(self):
        peak = max(self._costs) if self._costs else 1
        if self._cap:
            return max(peak, self._cap * CAP_HEADROOM)
        return max(peak, 1)

    def _is_keyframe(self, index):
        return (index < len(self._terms)
                and self._terms[index] in (OP_KFLIP, OP_KSTART))

    def _colour_for(self, cost, index=None):
        """Meter stops for a DELTA frame's cost against the cap.

        Keyframe spans are exempt: a full repaint is supposed to be
        expensive, so running one through the fault ramp would paint the
        encoder doing its job as a problem. They take a neutral
        structural grey instead - which also keeps the meter down to
        three colours, since grey is not one of the stops."""
        if index is not None and self._is_keyframe(index):
            return QColor(theme.INK_FAINT)
        if not self._cap:
            return QColor(theme.WIRE_UNDER)
        if cost >= self._cap:
            return QColor(theme.WIRE_OVER)
        if cost >= self._cap * theme.WIRE_NEAR_FRACTION:
            return QColor(theme.WIRE_NEAR)
        return QColor(theme.WIRE_UNDER)

    # -- interaction -----------------------------------------------------

    def mousePressEvent(self, event):
        if self._costs and event.button() == Qt.LeftButton:
            self.seek_requested.emit(self._frame_for_x(event.position().x()))
            event.accept()
            return
        super().mousePressEvent(event)

    def mouseMoveEvent(self, event):
        if self._costs and (event.buttons() & Qt.LeftButton):
            self.seek_requested.emit(self._frame_for_x(event.position().x()))
            event.accept()
            return
        self._update_hover_tip(event.position().x())
        super().mouseMoveEvent(event)

    def _update_hover_tip(self, x):
        if not self._costs:
            self.setToolTip("")
            return
        i = self._frame_for_x(x)
        cost = self._costs[i]
        text = f"f{i}  {cost:,} B"
        if self._cap:
            text += f"  ({cost / self._cap * 100:.0f}% of {self._cap:,} B cap)"
        if i < len(self._terms) and self._terms[i] in (OP_KFLIP, OP_KSTART):
            text += "  keyframe"
        self.setToolTip(text)

    # -- painting --------------------------------------------------------

    def paintEvent(self, _event):
        painter = QPainter(self)
        painter.setRenderHint(QPainter.Antialiasing, False)

        w, plot_h = self.width(), PLOT_HEIGHT
        well = QRectF(0, 0, w, plot_h)
        painter.setPen(Qt.NoPen)
        painter.setBrush(QColor(theme.INSET))
        painter.drawRoundedRect(well, theme.RADIUS_CONTROL, theme.RADIUS_CONTROL)

        if not self._costs:
            self._paint_empty(painter, well)
            self._paint_border(painter, well)
            painter.end()
            return

        self._paint_segment(painter, plot_h)
        self._paint_bars(painter, plot_h)
        self._paint_cap(painter, w, plot_h)
        self._paint_keyframes(painter, plot_h)
        self._paint_playhead(painter, plot_h)
        self._paint_border(painter, well)
        painter.end()

    def _paint_border(self, painter, well):
        painter.setBrush(Qt.NoBrush)
        painter.setPen(QPen(QColor(255, 255, 255, 18), 1))
        painter.drawRoundedRect(well.adjusted(0.5, 0.5, -0.5, -0.5),
                                theme.RADIUS_CONTROL, theme.RADIUS_CONTROL)

    def _paint_empty(self, painter, well):
        if not self._empty_text:
            return
        painter.setPen(QColor(theme.INK_GHOST))
        painter.setFont(theme.ui_font(8.5))
        painter.drawText(well, Qt.AlignCenter, self._empty_text)

    def _paint_segment(self, painter, plot_h):
        if self._seg_in is None and self._seg_out is None:
            return
        lo = self._seg_in if self._seg_in is not None else 0
        hi = self._seg_out if self._seg_out is not None else len(self._costs) - 1
        if hi < lo:
            lo, hi = hi, lo
        x0, x1 = self._x_for_frame(lo), self._x_for_frame(hi)
        accent = QColor(theme.ACCENT)
        fill = QColor(accent)
        fill.setAlpha(30)
        painter.setPen(Qt.NoPen)
        painter.setBrush(fill)
        painter.drawRect(QRectF(x0, 0, max(1.0, x1 - x0), plot_h))
        edge = QColor(accent)
        edge.setAlpha(150)
        painter.setPen(QPen(edge, 1))
        for frame, present in ((self._seg_in, self._seg_in is not None),
                               (self._seg_out, self._seg_out is not None)):
            if present:
                x = self._x_for_frame(frame)
                painter.drawLine(int(x), 0, int(x), plot_h)

    def _paint_bars(self, painter, plot_h):
        """One bar per x pixel, carrying the MAX cost of the frames that
        land on it - never the mean. A burst is a single expensive frame
        among cheap ones, so averaging a column is exactly the way to
        hide the thing this widget exists to show."""
        top = self._top_value()
        buckets = {}
        for i, cost in enumerate(self._costs):
            x = int(self._x_for_frame(i))
            if cost > buckets.get(x, (-1, 0))[0]:
                buckets[x] = (cost, i)

        painter.setPen(Qt.NoPen)
        for x, (cost, index) in buckets.items():
            h = max(1.0, (cost / top) * (plot_h - 2))
            colour = self._colour_for(cost, index)
            colour.setAlpha(210)
            painter.setBrush(colour)
            painter.drawRect(QRectF(x, plot_h - h - 1, 1.0, h))

    def _paint_cap(self, painter, w, plot_h):
        if not self._cap:
            return
        y = plot_h - 1 - (self._cap / self._top_value()) * (plot_h - 2)
        # Dashed, not solid: a solid rule across a chart reads as a
        # gridline, and this is a limit. The dash is the convention that
        # says "you do not cross this".
        pen = QPen(QColor(255, 255, 255, 110), 1, Qt.DashLine)
        pen.setDashPattern([3, 3])
        painter.setPen(pen)
        painter.drawLine(0, int(y), w, int(y))

        # Three characters that stop the line being a mystery. Dropped
        # rather than crowded when the strip is too narrow to hold it.
        label = "cap"
        painter.setFont(theme.ui_font(8))
        metrics = painter.fontMetrics()
        label_w = metrics.horizontalAdvance(label)
        if w > label_w + 8 * INSET:
            # Above the line normally; below it when the cap sits too
            # high to fit - a headroom-rich clip pushes the line near
            # the top, which is exactly when the label used to vanish.
            above = y > metrics.height()
            baseline = y - 3 if above else y + metrics.ascent() + 2
            left = w - label_w - INSET - 2
            # A clip that is dense right to its final frame has bars
            # under the label wherever it goes, so it carries its own
            # backing rather than competing with the data.
            painter.setPen(Qt.NoPen)
            backing = QColor(theme.INSET)
            backing.setAlpha(225)
            painter.setBrush(backing)
            painter.drawRect(QRectF(left - 2, baseline - metrics.ascent() - 1,
                                    label_w + 4, metrics.height()))
            painter.setPen(QColor(theme.INK_DIM))
            painter.drawText(int(left), int(baseline), label)

    def _paint_keyframes(self, painter, plot_h):
        """Keyframe spans are legitimately expensive - a full repaint,
        not a delta that overran - so they are marked structurally (a
        tick in the lane below) rather than coloured like a fault."""
        if not self._terms:
            return
        painter.setPen(QPen(QColor(theme.INK_GHOST), 1))
        seen = set()
        for i, term in enumerate(self._terms):
            if term not in (OP_KFLIP, OP_KSTART):
                continue
            x = int(self._x_for_frame(i))
            if x in seen:
                continue
            seen.add(x)
            painter.drawLine(x, plot_h + 1, x, plot_h + TICK_LANE - 2)

    def _paint_playhead(self, painter, plot_h):
        x = int(self._x_for_frame(self._playhead))
        painter.setPen(QPen(QColor(theme.INK), 1))
        painter.drawLine(x, 0, x, plot_h)
