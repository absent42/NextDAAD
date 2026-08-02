"""Visual tokens and the application stylesheet.

vidtune is a bench instrument for judging a 256-colour clip against a hard
wire budget, so the chrome is built to get out of the way of the picture:
a near-black grading surround (a light chrome around a 256-colour still
lies about how it looks), one accent, and figures in a monospace face so a
changing number never shifts the layout it sits in.

Token groups
------------
Surfaces are one hue - a cool near-black - separated by lightness only,
in whisper-quiet steps: SURROUND (behind the picture, the darkest thing on
screen) -> PANEL -> RAISED (menus, hover) -> INSET (inputs, which sit
BELOW their surroundings because they receive content).

Text has four levels - INK / INK_DIM / INK_FAINT / INK_GHOST - so
hierarchy comes from weight and colour rather than size.

Colour means one thing each. ACCENT (blue) is the only UI accent:
selection, focus, and the single primary action. The trace's
green/amber/red are NOT decoration - they are meter stops encoding wire
cost against the per-frame cap, and they are deliberately kept out of the
blues so the accent stays the one thing that means "act here".

Deliberately no motion: Play/step/Preview Segment get hammered hundreds of
times in a tuning session, and animating a control at that repetition rate
only makes it feel slow.
"""
from PySide6.QtGui import QColor, QFont

# -- surfaces (one hue, lightness only) ---------------------------------
SURROUND = "#0a0b0d"     # grading surround - behind the picture only
PANEL    = "#121418"     # the app canvas and its panes
RAISED   = "#191c21"     # menus, hover, the raised strip under the picture
INSET    = "#0e1013"     # inputs - darker than their surroundings

# -- edges (low-alpha, so they define without demanding attention) -------
EDGE      = "rgba(255,255,255,0.07)"
EDGE_SOFT = "rgba(255,255,255,0.045)"
EDGE_LIT  = "rgba(255,255,255,0.14)"

# -- text ---------------------------------------------------------------
INK       = "#e8eaed"
INK_DIM   = "#a8aeb8"
INK_FAINT = "#6f7681"
INK_GHOST = "#464c55"

# -- meaning ------------------------------------------------------------
# The accent clears 4.5:1 on PANEL as small bold label text (5.82) and
# gives 6.31 for the dark label on a primary button fill - it has to work
# as BOTH, since it marks deviating knobs as well as filling Accept.
ACCENT   = "#5a8cff"     # selection, focus, primary action, deviation
PHOSPHOR = "#d9a441"     # caution - provisional budget, stale clip
FAULT    = "#d5453f"     # a hardware red, not the alert-box red this replaced
HEADROOM = "#4fb06a"     # healthy - room under the cap, a clip already tuned

# Trace meter stops: green below the cap, amber as it closes on it, red at
# or over. A green-amber-red ramp is the headroom meter everyone already
# knows how to read, and keeping the ramp out of the blues is what lets
# the accent stay the ONE thing that means "UI, act here" - the segment
# region is drawn in accent directly over these bars, and the slider
# shares their axis, so a blue datum would blur the two jobs.
WIRE_UNDER = HEADROOM
WIRE_NEAR  = PHOSPHOR
WIRE_OVER  = FAULT
WIRE_NEAR_FRACTION = 0.85   # of the per-frame cap

# -- spacing / radius ---------------------------------------------------
UNIT   = 4               # everything is a multiple of this
GAP_ROW  = UNIT * 2      # 8  - within a row of controls
GAP_PANE = UNIT * 3      # 12 - inside a panel
GAP_ZONE = UNIT * 4      # 16 - between zones

RADIUS_CONTROL = 3       # inputs, buttons
RADIUS_PANEL   = 6       # panes, group boxes

CONTROL_HEIGHT = 26
SLIDER_HANDLE_WIDTH = 8  # WireTrace insets by half this to share the axis

UI_FAMILIES     = ["Segoe UI", "Inter", "system-ui"]
FIGURE_FAMILIES = ["Cascadia Mono", "Consolas", "DejaVu Sans Mono"]


def rgba(hex_colour, alpha):
    c = QColor(hex_colour)
    return f"rgba({c.red()},{c.green()},{c.blue()},{alpha})"


def figure_font(point_size=10, bold=False):
    """Monospace face for any figure that changes - PSNR, utilisation,
    frame counts, byte totals. Monospace IS the tabular-figures rule here:
    a digit is always the same width, so a counter ticking over never
    nudges the labels beside it."""
    font = QFont()
    font.setFamilies(FIGURE_FAMILIES)
    font.setPointSizeF(point_size)
    font.setBold(bold)
    return font


def ui_font(point_size=9.5, bold=False):
    font = QFont()
    font.setFamilies(UI_FAMILIES)
    font.setPointSizeF(point_size)
    font.setBold(bold)
    return font


def caption_font(point_size=8):
    """Small, tracked-out, upper-case captions - the demoted half of a
    metric, so the figure itself can lead."""
    font = ui_font(point_size)
    font.setCapitalization(QFont.AllUppercase)
    font.setLetterSpacing(QFont.PercentageSpacing, 108)
    return font


def stylesheet():
    """The application stylesheet. Applied to the MainWindow (so a
    test-constructed window is themed too) and to the QApplication in
    __main__, which also catches menus and message boxes."""
    return f"""
QWidget {{
    background: {PANEL};
    color: {INK};
}}
QToolTip {{
    background: {RAISED};
    color: {INK};
    border: 1px solid {EDGE_LIT};
    padding: {UNIT}px {GAP_ROW}px;
}}

/* -- buttons: quiet by default, one primary ------------------------- */
QPushButton {{
    background: {RAISED};
    color: {INK_DIM};
    border: 1px solid {EDGE};
    border-radius: {RADIUS_CONTROL}px;
    padding: {UNIT}px {GAP_PANE}px;
    min-height: {CONTROL_HEIGHT - 2 * UNIT}px;
}}
QPushButton:hover {{
    color: {INK};
    border-color: {EDGE_LIT};
}}
QPushButton:pressed {{
    /* Qt stylesheets cannot transform, so the press reads as the label
       settling 1px - the same tactile confirmation a scale would give. */
    padding-top: {UNIT + 1}px;
    padding-bottom: {UNIT - 1}px;
    background: {INSET};
}}
QPushButton:checked {{
    background: {rgba(ACCENT, 0.16)};
    color: {INK};
    border-color: {rgba(ACCENT, 0.55)};
}}
QPushButton:disabled {{
    color: {INK_GHOST};
    border-color: {EDGE_SOFT};
    background: {PANEL};
}}
QPushButton:focus {{
    border-color: {ACCENT};
}}
/* The one primary action on screen. */
QPushButton[primary="true"] {{
    background: {ACCENT};
    color: #050814;
    border: 1px solid {ACCENT};
    font-weight: 600;
}}
QPushButton[primary="true"]:hover  {{ background: #6f9bff; }}
QPushButton[primary="true"]:pressed{{ background: #4576e0; }}
QPushButton[primary="true"]:disabled {{
    background: {PANEL};
    color: {INK_GHOST};
    border-color: {EDGE_SOFT};
}}

/* -- inputs: inset, so they read as "type here" without heavy borders */
QLineEdit, QComboBox {{
    background: {INSET};
    color: {INK};
    border: 1px solid {EDGE};
    border-radius: {RADIUS_CONTROL}px;
    padding: {UNIT - 1}px {GAP_ROW}px;
    min-height: {CONTROL_HEIGHT - 2 * UNIT}px;
    selection-background-color: {rgba(ACCENT, 0.45)};
}}
QLineEdit:hover, QComboBox:hover {{ border-color: {EDGE_LIT}; }}
QLineEdit:focus, QComboBox:focus {{ border-color: {ACCENT}; }}
QLineEdit:disabled, QComboBox:disabled {{
    color: {INK_GHOST};
    border-color: {EDGE_SOFT};
}}
QComboBox::drop-down {{ border: none; width: {GAP_ZONE}px; }}
QComboBox::down-arrow {{
    /* No image asset: a small square in the faint ink reads as an
       affordance at this size without shipping an icon. */
    width: 5px; height: 5px;
    background: {INK_FAINT};
}}
QComboBox QAbstractItemView {{
    background: {RAISED};
    border: 1px solid {EDGE_LIT};
    selection-background-color: {rgba(ACCENT, 0.28)};
    outline: none;
}}

QCheckBox {{ color: {INK_DIM}; spacing: {GAP_ROW}px; }}
QCheckBox::indicator {{
    width: 13px; height: 13px;
    border: 1px solid {EDGE_LIT};
    border-radius: 2px;
    background: {INSET};
}}
QCheckBox::indicator:checked {{
    background: {ACCENT};
    border-color: {ACCENT};
}}
QCheckBox:disabled {{ color: {INK_GHOST}; }}

/* -- the clip rail --------------------------------------------------- */
QListWidget {{
    background: {PANEL};
    border: 1px solid {EDGE_SOFT};
    border-radius: {RADIUS_PANEL}px;
    outline: none;
    padding: {UNIT}px;
}}
QListWidget::item {{
    padding: {GAP_ROW - 1}px {GAP_ROW}px;
    border-radius: {RADIUS_CONTROL}px;
    color: {INK_DIM};
}}
QListWidget::item:hover {{ background: {RAISED}; color: {INK}; }}
QListWidget::item:selected {{
    background: {rgba(ACCENT, 0.18)};
    color: {INK};
}}

/* -- settings rail --------------------------------------------------- */
QScrollArea {{ border: none; }}
/* A disclosure, not a container: a bordered box would draw an empty
   well under the toggle whenever the section is collapsed, which is
   most of the time. A rule above it separates the section instead. */
QGroupBox {{
    border: none;
    border-top: 1px solid {EDGE_SOFT};
    margin-top: {GAP_PANE}px;
    padding: {GAP_PANE}px 0 0 0;
    color: {INK_FAINT};
}}
QGroupBox::title {{
    subcontrol-origin: margin;
    left: 0;
    padding: 0 {UNIT}px 0 0;
    color: {INK_FAINT};
}}
QGroupBox::indicator {{
    width: 11px; height: 11px;
    border: 1px solid {EDGE_LIT};
    border-radius: 2px;
    background: {INSET};
}}
QGroupBox::indicator:checked {{ background: {INK_FAINT}; border-color: {INK_FAINT}; }}

/* -- transport ------------------------------------------------------- */
QSlider::groove:horizontal {{
    height: 3px;
    background: {INSET};
    border: 1px solid {EDGE_SOFT};
    border-radius: 2px;
}}
QSlider::sub-page:horizontal {{
    background: {rgba(ACCENT, 0.5)};
    border-radius: 2px;
}}
QSlider::handle:horizontal {{
    width: {SLIDER_HANDLE_WIDTH}px;
    margin: -5px 0;
    background: {INK};
    border-radius: 2px;
}}
QSlider::handle:horizontal:hover {{ background: {ACCENT}; }}
QSlider:disabled::handle:horizontal {{ background: {INK_GHOST}; }}

QProgressBar {{
    background: {INSET};
    border: 1px solid {EDGE_SOFT};
    border-radius: 2px;
    height: {GAP_ROW}px;
    text-align: center;
    color: transparent;
}}
QProgressBar::chunk {{ background: {ACCENT}; border-radius: 2px; }}

/* -- scrollbars: present when needed, invisible otherwise ------------ */
QScrollBar:vertical {{
    background: transparent; width: {GAP_ROW}px; margin: 0;
}}
QScrollBar::handle:vertical {{
    background: {rgba(INK_FAINT, 0.45)};
    border-radius: {UNIT}px;
    min-height: {GAP_ZONE}px;
}}
QScrollBar::handle:vertical:hover {{ background: {rgba(INK_FAINT, 0.75)}; }}
QScrollBar:horizontal {{
    background: transparent; height: {GAP_ROW}px; margin: 0;
}}
QScrollBar::handle:horizontal {{
    background: {rgba(INK_FAINT, 0.45)};
    border-radius: {UNIT}px;
    min-width: {GAP_ZONE}px;
}}
QScrollBar::add-line, QScrollBar::sub-line {{ height: 0; width: 0; }}
QScrollBar::add-page, QScrollBar::sub-page {{ background: transparent; }}

QSplitter::handle {{ background: {PANEL}; }}
QSplitter::handle:horizontal {{ width: {GAP_ROW}px; }}
QSplitter::handle:hover {{ background: {RAISED}; }}

QTextEdit {{
    background: {INSET};
    border: 1px solid {EDGE};
    border-radius: {RADIUS_CONTROL}px;
    color: {INK_DIM};
    selection-background-color: {rgba(ACCENT, 0.45)};
}}

QStatusBar {{ color: {INK_FAINT}; border-top: 1px solid {EDGE_SOFT}; }}
QStatusBar::item {{ border: none; }}
QMenuBar, QMenu {{ background: {RAISED}; color: {INK_DIM}; }}
QMenu::item:selected {{ background: {rgba(ACCENT, 0.28)}; color: {INK}; }}
"""
