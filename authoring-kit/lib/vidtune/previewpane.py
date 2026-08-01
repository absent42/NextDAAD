"""PreviewPane: playback, flicker toggle, heatmap, segment markers.

Displays the decoded/encoded preview against the source frames built by
preview.py (decode_vid, extract_source, diff_heatmap, stale_bands).
Frame injection for tests/direct callers is set_frames(); load() wraps
decode_vid in a QThread worker (decode is the only slow step here -
source_frames arrives already extracted, built by the caller from
extract_source) so the GUI thread never blocks on a big .vid file, with
a busy label meanwhile and decode errors landing in a red label rather
than crashing the tool.
"""
import numpy as np

from PySide6.QtCore import QObject, Qt, QThread, QTimer, Signal
from PySide6.QtGui import QImage, QPixmap
from PySide6.QtWidgets import (
    QButtonGroup,
    QCheckBox,
    QHBoxLayout,
    QLabel,
    QPushButton,
    QSizePolicy,
    QSlider,
    QVBoxLayout,
    QWidget,
)

from .preview import decode_vid, diff_heatmap, stale_bands

DEFAULT_FPS = 25.0
MODES = ("Encoded", "Flicker", "Heatmap")
NEEDS_SOURCE_TOOLTIP = "needs a source comparison - run Preview Segment or Encode first"
NOT_ENCODED_TOOLTIP = "not encoded yet"
SOURCE_PREVIEW_HINT = "source preview - not encoded yet"


class _ClickableLabel(QLabel):
    """QLabel with a clicked signal - used for the image view so a
    click in Flicker mode toggles source/encoded like spacebar does."""

    clicked = Signal()

    def mousePressEvent(self, event):
        self.clicked.emit()
        super().mousePressEvent(event)


class _DecodeWorker(QObject):
    """Runs decode_vid() off the GUI thread. Lives on its own QThread
    (moveToThread pattern, not a QThread subclass, per Qt's own
    guidance) so a big .vid file never blocks the UI.

    The load() generation is carried in the signal payload (not a
    lambda closure) on purpose: connecting done/failed to a bare
    lambda gives the connection no receiver QObject, so Qt resolves
    the implicit connection context to the SENDER - this worker, which
    lives on the decode thread - and silently downgrades what looks
    like a cross-thread signal to a Direct connection. The slot would
    then run ON THE DECODE THREAD, mutating widgets from off the GUI
    thread. Connecting to a bound method of the pane (a QObject that
    lives on the GUI thread) instead gives Qt the correct receiver
    affinity, so PySide auto-selects Qt.QueuedConnection and the slot
    runs on the GUI thread as required."""

    done = Signal(object, object, int)     # hdr, frames, generation
    failed = Signal(str, int)              # message, generation

    def __init__(self, vid_path, gen):
        super().__init__()
        self.vid_path = vid_path
        self.gen = gen

    def run(self):
        try:
            hdr, frames = decode_vid(self.vid_path)
        except Exception as exc:  # noqa: BLE001 - surfaced in the pane, not raised
            self.failed.emit(str(exc), self.gen)
            return
        self.done.emit(hdr, frames, self.gen)


class _ExtractWorker(QObject):
    """Runs an arbitrary zero-arg extraction callable off the GUI thread
    - used by PreviewPane.load_source() for ffmpeg-based extraction of
    an un-encoded clip's source preview frames. Same QueuedConnection/
    generation-in-payload reasoning as _DecodeWorker (see its docstring
    for why a bare lambda receiver would be wrong). The callable itself
    is built by the caller (MainWindow._load_source_preview) from plain
    values only - no Qt widget access - so it is safe to actually run
    here, on the extraction thread."""

    done = Signal(object, int)     # frames, generation
    failed = Signal(str, int)      # message, generation

    def __init__(self, extract_fn, gen):
        super().__init__()
        self.extract_fn = extract_fn
        self.gen = gen

    def run(self):
        try:
            frames = self.extract_fn()
        except Exception as exc:  # noqa: BLE001 - surfaced in the pane, not raised
            self.failed.emit(str(exc), self.gen)
            return
        self.done.emit(frames, self.gen)


class PreviewPane(QWidget):
    """Encoded/Flicker/Heatmap preview with transport controls and
    in/out segment markers (frame indices, converted to seconds for
    the encoder's --start/--duration via segment_times())."""

    # Emitted only from a user-initiated Clear button click - NOT from
    # the plain clear() method itself, which MainWindow.select_clip also
    # calls (programmatically) to reset the pane's live markers when
    # switching clips. If that programmatic clear also emitted this
    # signal, switching to a clip would pop its own just-loaded stored
    # segment out from under it (see MainWindow._on_pane_cleared).
    cleared = Signal()

    def __init__(self, parent=None):
        super().__init__(parent)
        self.encoded = None
        self.source = None
        self.fps = DEFAULT_FPS
        self.column_major = False
        self.frame_index = 0
        self.mode = "Encoded"
        self.showing_source = False
        self.seg_in = None
        self.seg_out = None
        self.scale = 2          # owner-requested default (2026-08-01);
                                 # _scale_btn.setChecked(True) below keeps
                                 # the toggle control and the initial
                                 # render in sync with this
        self._playing = False
        self._heatmap_cache = {}
        self._last_buffer = None
        self._thread = None
        self._worker = None
        self._threads = []            # decode threads still alive, oldest first
        self._workers = []            # their matching workers - kept referenced
        self._load_gen = 0            # bumped on every load(); stale decode
                                       # results (from an abandoned prior
                                       # load()) are dropped by comparing
                                       # against this in _on_decode_done/failed
        self._pending_source = None
        self._pending_column_major = False
        self._pending_source_fps = None       # load_source()'s pending fps/
        self._pending_source_column_major = False  # column_major/hint, set at
        self._pending_source_hint = None      # call time, applied in _on_extract_done

        self.setFocusPolicy(Qt.StrongFocus)

        self._timer = QTimer(self)
        self._timer.timeout.connect(self._on_timer)

        self._busy_label = QLabel("Decoding...")
        self._busy_label.setVisible(False)

        self._error_label = QLabel("")
        self._error_label.setStyleSheet("color: white; background-color: #a02020; padding: 2px;")
        self._error_label.setWordWrap(True)
        self._error_label.setVisible(False)

        # Neutral (non-error) status text for an empty pane - e.g. a
        # newly-selected clip with no fresh .vid to preview yet - so
        # that state reads as "nothing to show" rather than "broken".
        self._hint_label = QLabel("")
        self._hint_label.setStyleSheet(
            "color: #dddddd; background-color: #333333; padding: 2px;")
        self._hint_label.setWordWrap(True)
        self._hint_label.setVisible(False)

        self._image_label = _ClickableLabel()
        self._image_label.setAlignment(Qt.AlignCenter)
        self._image_label.setMinimumSize(64, 64)
        self._image_label.clicked.connect(self._on_image_clicked)

        self._mode_buttons = {}
        mode_group = QButtonGroup(self)
        mode_group.setExclusive(True)
        mode_row = QHBoxLayout()
        for name in MODES:
            btn = QPushButton(name)
            btn.setCheckable(True)
            # NoFocus keeps keyboard focus on the pane itself (StrongFocus)
            # after a click, so the Space handler in keyPressEvent still
            # sees the key - otherwise Qt routes Space to the just-clicked
            # button instead of the pane's flicker/play toggle.
            btn.setFocusPolicy(Qt.NoFocus)
            # Maximum (not the QPushButton default Preferred-with-hstretch)
            # keeps these three buttons sized to their own caption + style
            # padding instead of expanding to fill the row - owner
            # feedback (2026-08-01): the mode row was eating far more
            # width than three short captions need, starving the video
            # preview itself.
            btn.setSizePolicy(QSizePolicy.Maximum, QSizePolicy.Fixed)
            btn.clicked.connect(lambda checked=False, n=name: self.set_mode(n))
            mode_group.addButton(btn)
            mode_row.addWidget(btn)
            self._mode_buttons[name] = btn
        mode_row.addStretch(1)
        self._mode_buttons["Encoded"].setChecked(True)
        # Enabled state + tooltip for all three are set dynamically by
        # _update_mode_buttons() (called at the end of __init__) - no
        # static setToolTip here, since which of NEEDS_SOURCE_TOOLTIP /
        # NOT_ENCODED_TOOLTIP applies depends on encoded/source state.

        self._scrub_slider = QSlider(Qt.Horizontal)
        self._scrub_slider.setFocusPolicy(Qt.NoFocus)   # same reasoning as the buttons below
        self._scrub_slider.setEnabled(False)
        self._scrub_slider.setRange(0, 0)
        self._scrub_slider.valueChanged.connect(self._on_scrub_slider_changed)

        self._play_btn = QPushButton("Play")
        self._play_btn.clicked.connect(self.toggle_play)
        self._stop_btn = QPushButton("Stop")
        self._stop_btn.clicked.connect(self.stop)
        self._step_back_btn = QPushButton("<")
        self._step_back_btn.clicked.connect(lambda: self.step(-1))
        self._step_fwd_btn = QPushButton(">")
        self._step_fwd_btn.clicked.connect(lambda: self.step(+1))
        self._loop_checkbox = QCheckBox("Loop")
        self._frame_label = QLabel("frame 0/0")
        self._set_in_btn = QPushButton("Set In")
        self._set_in_btn.clicked.connect(self.set_in)
        self._set_out_btn = QPushButton("Set Out")
        self._set_out_btn.clicked.connect(self.set_out)
        self._clear_btn = QPushButton("Clear")
        self._clear_btn.clicked.connect(self._on_clear_clicked)
        self._segment_label = QLabel("segment: -")
        self._scale_btn = QPushButton("2x")
        self._scale_btn.setCheckable(True)
        self._scale_btn.toggled.connect(self._on_scale_toggled)
        # Reflect the 2x default on the toggle itself; _on_scale_toggled
        # re-sets self.scale (redundant with the __init__ default above,
        # harmless) and calls _render() so the initial render already
        # honours 2x once frames arrive.
        self._scale_btn.setChecked(True)

        # Same NoFocus reasoning as the mode buttons above - every
        # clickable control in the transport row must give focus back to
        # the pane, not keep it, or Space stops reaching keyPressEvent.
        for btn in (self._play_btn, self._stop_btn, self._step_back_btn,
                    self._step_fwd_btn, self._loop_checkbox,
                    self._set_in_btn, self._set_out_btn, self._clear_btn,
                    self._scale_btn):
            btn.setFocusPolicy(Qt.NoFocus)

        # Two compact rows instead of one wide one (owner feedback,
        # 2026-08-01): the single transport row's minimum width - driven
        # by ~11 buttons/labels laid out side by side - was the dominant
        # term in the pane's overall minimumSizeHint, starving the
        # settings/preview split. Splitting playback controls from
        # marker/scale controls roughly halves that floor. Object names
        # and behaviour are unchanged - only which layout each widget
        # sits in.
        playback_row = QHBoxLayout()
        for w in (self._play_btn, self._stop_btn, self._step_back_btn,
                  self._step_fwd_btn, self._loop_checkbox):
            playback_row.addWidget(w)
        playback_row.addStretch(1)

        marker_row = QHBoxLayout()
        for w in (self._frame_label, self._set_in_btn, self._set_out_btn,
                  self._clear_btn, self._segment_label, self._scale_btn):
            marker_row.addWidget(w)
        marker_row.addStretch(1)

        outer = QVBoxLayout(self)
        outer.addWidget(self._busy_label)
        outer.addWidget(self._error_label)
        outer.addWidget(self._hint_label)
        outer.addWidget(self._image_label, 1)
        outer.addLayout(mode_row)
        outer.addWidget(self._scrub_slider)
        outer.addLayout(playback_row)
        outer.addLayout(marker_row)

        self._update_mode_buttons()
        self._update_segment_readout()

    # -- frame injection / loading ----------------------------------

    def set_frames(self, encoded, source, fps, column_major):
        # A direct injection path (set_frames is also called from
        # load()'s vid_path-is-None branch and from clear_to_empty())
        # must invalidate any in-flight decode the same way a fresh
        # load() does, or a late decode-done callback for a now-
        # abandoned load can still land afterwards.
        self._load_gen += 1
        self._stop_playback()
        self.encoded = list(encoded) if encoded is not None else None
        self.source = list(source) if source is not None else None
        self.fps = float(fps) if fps else DEFAULT_FPS
        self.column_major = bool(column_major)
        self.frame_index = 0
        self.showing_source = False
        self.seg_in = None
        self.seg_out = None
        self._heatmap_cache = {}
        self._hint_label.setVisible(False)
        if self.mode == "Heatmap" and not self._heatmap_available():
            self.mode = "Encoded"
        if self.mode == "Flicker" and not (self.encoded is not None and self.source is not None):
            self.mode = "Encoded"
        self._update_mode_buttons()
        self._update_segment_readout()
        self._sync_scrub_slider_range()
        if self.encoded is None and self.source is not None:
            # Un-encoded clip's source frames (MainWindow._load_source_preview)
            # - flagged here (not just by the caller) so any direct
            # set_frames(encoded=None, source=...) injection gets the
            # same "not encoded yet" framing without every caller having
            # to remember to say so. A caller with a more specific hint
            # (e.g. the "showing first Ns of source" cap note) overrides
            # this right after set_frames() returns - see
            # _on_extract_done.
            self.show_hint(SOURCE_PREVIEW_HINT)
        self._render()

    def load(self, vid_path, source_frames, column_major):
        """Decodes vid_path (if given) on a QThread worker, then calls
        set_frames on the GUI thread. Either side may be None - source
        only (before first encode) or encoded only (extraction
        failed). Decode errors show in a red label; the tool stays
        up.

        A fresh call bumps self._load_gen; the decode-done/failed
        callbacks capture their own generation number at connect time
        and drop the result if a newer load() has started in the
        meantime (self._load_gen has moved on) - this is what makes a
        second load() while the first is still decoding safe: the
        stale worker's result is ignored rather than clobbering
        set_frames with the wrong pairing of encoded/source frames.
        The stale thread/worker are not killed (decode_vid isn't
        interruptible mid-read) - they are left to finish naturally,
        kept referenced in self._threads/self._workers so they are
        never garbage-collected out from under a still-running QThread,
        and cleaned up (deleteLater) once their own finished signal
        fires."""
        self._error_label.setVisible(False)
        self._error_label.setText("")
        self._pending_source = source_frames
        self._pending_column_major = column_major
        self._load_gen += 1
        gen = self._load_gen

        if vid_path is None:
            self._show_busy(False)
            self.set_frames(encoded=None, source=source_frames,
                             fps=self.fps, column_major=column_major)
            return

        self._show_busy(True)
        thread = QThread(self)
        worker = _DecodeWorker(vid_path, gen)
        worker.moveToThread(thread)
        thread.started.connect(worker.run)
        # Bound methods of self (a QObject living on the GUI thread)
        # give Qt the correct receiver affinity for these cross-thread
        # signals, so the connection is auto-promoted to Queued and
        # the slots run on the GUI thread - see _DecodeWorker's
        # docstring for why a lambda here would be wrong.
        worker.done.connect(self._on_decode_done)
        worker.failed.connect(self._on_decode_failed)
        worker.done.connect(thread.quit)
        worker.failed.connect(thread.quit)
        thread.finished.connect(lambda t=thread, w=worker: self._on_thread_finished(t, w))
        # Keep references alive until the thread's own finished signal
        # fires - overwriting self._thread/self._worker on the next
        # load() must not drop the only Python reference to a still-
        # running QThread.
        self._threads.append(thread)
        self._workers.append(worker)
        self._thread = thread
        self._worker = worker
        thread.start()

    def _on_thread_finished(self, thread, worker):
        if thread in self._threads:
            self._threads.remove(thread)
        if worker in self._workers:
            self._workers.remove(worker)
        if self._thread is thread:
            self._thread = None
        if self._worker is worker:
            self._worker = None
        thread.deleteLater()
        worker.deleteLater()

    def _on_decode_done(self, hdr, frames, gen):
        if gen != self._load_gen:
            return  # stale result from an abandoned load(); ignore
        self._show_busy(False)
        fps = hdr.get("fps_x10", int(DEFAULT_FPS * 10)) / 10.0
        column_major = hdr.get("column_major", self._pending_column_major)
        self.set_frames(encoded=frames, source=self._pending_source,
                         fps=fps, column_major=column_major)

    def _on_decode_failed(self, message, gen):
        if gen != self._load_gen:
            return  # stale result from an abandoned load(); ignore
        self._show_busy(False)
        self._error_label.setText(message)
        self._error_label.setVisible(True)

    def load_source(self, extract_fn, fps, column_major, hint=None):
        """Runs extract_fn() (a zero-arg callable with NO Qt widget
        access - see MainWindow._load_source_preview, which builds it
        from plain values captured on the GUI thread before handing it
        off) on a QThread, then injects the result as source-only frames
        (encoded=None) via set_frames(). Used for a clip with no fresh
        .vid yet, so the user can scrub the timeline and mark Set In/
        Set Out before ever running an encode.

        Same generation-guard pattern as load(): a fresh call bumps
        self._load_gen, and the worker's done/failed signals carry the
        generation they were started with, so switching clips mid-
        extract drops the stale result (_on_extract_done/failed) instead
        of painting it over whatever the user has since switched to."""
        self._error_label.setVisible(False)
        self._error_label.setText("")
        self._pending_source_fps = fps
        self._pending_source_column_major = column_major
        self._pending_source_hint = hint
        self._load_gen += 1
        gen = self._load_gen

        self._show_busy(True, "loading source...")
        thread = QThread(self)
        worker = _ExtractWorker(extract_fn, gen)
        worker.moveToThread(thread)
        thread.started.connect(worker.run)
        # Bound methods of self - see _DecodeWorker's docstring for why
        # this (not a bare lambda) is what gives Qt the receiver
        # affinity needed to run these slots on the GUI thread.
        worker.done.connect(self._on_extract_done)
        worker.failed.connect(self._on_extract_failed)
        worker.done.connect(thread.quit)
        worker.failed.connect(thread.quit)
        thread.finished.connect(lambda t=thread, w=worker: self._on_thread_finished(t, w))
        self._threads.append(thread)
        self._workers.append(worker)
        self._thread = thread
        self._worker = worker
        thread.start()

    def _on_extract_done(self, frames, gen):
        if gen != self._load_gen:
            return  # stale result from an abandoned load_source(); ignore
        self._show_busy(False)
        self.set_frames(encoded=None, source=frames,
                         fps=self._pending_source_fps,
                         column_major=self._pending_source_column_major)
        if self._pending_source_hint:
            self.show_hint(self._pending_source_hint)

    def _on_extract_failed(self, message, gen):
        if gen != self._load_gen:
            return  # stale result from an abandoned load_source(); ignore
        self._show_busy(False)
        self._error_label.setText(message)
        self._error_label.setVisible(True)

    def _show_busy(self, busy, text="Decoding..."):
        if busy:
            self._busy_label.setText(text)
        self._busy_label.setVisible(busy)

    def show_error(self, message):
        """Shows an error message without touching the current frames -
        used when e.g. source extraction for the Flicker/Heatmap
        comparison fails but the encoded preview itself already loaded
        fine (an HH:MM:SS --start used to fail this silently with no
        message at all)."""
        self._error_label.setText(message)
        self._error_label.setVisible(True)

    def show_hint(self, message):
        """Neutral (non-error) status text - used when the pane has no
        frames to show yet."""
        self._hint_label.setText(message or "")
        self._hint_label.setVisible(bool(message))

    def clear_to_empty(self, hint=None):
        """Resets the pane to a blank state - no encoded/source frames,
        segment markers cleared, any earlier error cleared - with an
        optional hint label. Used by MainWindow.select_clip when the
        newly-selected clip has no fresh .vid to preview yet."""
        self._load_gen += 1
        self._error_label.setVisible(False)
        self._error_label.setText("")
        self.set_frames(encoded=None, source=None, fps=self.fps,
                        column_major=self.column_major)
        self.show_hint(hint)

    def closeEvent(self, event):
        self._shutdown_threads()
        super().closeEvent(event)

    def _shutdown_threads(self):
        """Blocks until every in-flight decode thread has actually
        stopped, so the pane never gets torn down out from under a
        running QThread (Qt aborts/crashes on that)."""
        for thread in list(self._threads):
            thread.quit()
            thread.wait()

    # -- mode / flicker -----------------------------------------------

    def _heatmap_available(self):
        return bool(self.encoded) and bool(self.source)

    def set_mode(self, name):
        if name not in MODES:
            return
        # Programmatic fallback kept for safety even though the buttons
        # themselves are now disabled while unavailable (Finding 1) -
        # set_mode can still be called directly (tests, future callers)
        # with no source/encoded pairing to compare.
        if name == "Heatmap" and not self._heatmap_available():
            name = "Encoded"
        if name == "Flicker" and not (self.encoded is not None and self.source is not None):
            name = "Encoded"
        self.mode = name
        self._update_mode_buttons()
        self._render()

    def toggle_flicker(self):
        self.showing_source = not self.showing_source
        self._render()

    def _on_image_clicked(self):
        if self.mode == "Flicker":
            self.toggle_flicker()

    def _update_mode_buttons(self):
        for name, btn in self._mode_buttons.items():
            btn.blockSignals(True)
            btn.setChecked(name == self.mode)
            btn.blockSignals(False)

        has_encoded = self.encoded is not None
        has_source = self.source is not None

        # Nothing is meaningfully "Encoded"/"Flicker"/"Heatmap" until
        # something has actually been encoded - a not-yet-encoded clip's
        # source-only preview (MainWindow._load_source_preview) disables
        # all three, with a "not encoded yet" tooltip, rather than
        # leaving Flicker/Encoded usable with nothing to compare or
        # encode-view. Once encoded frames exist, Flicker/Heatmap fall
        # back to the original per-button gating (each needs source too).
        self._mode_buttons["Encoded"].setEnabled(has_encoded)
        self._mode_buttons["Flicker"].setEnabled(has_encoded and has_source)
        self._mode_buttons["Heatmap"].setEnabled(self._heatmap_available())

        for name, btn in self._mode_buttons.items():
            if btn.isEnabled():
                btn.setToolTip("")
            elif not has_encoded and has_source:
                btn.setToolTip(NOT_ENCODED_TOOLTIP)
            else:
                btn.setToolTip(NEEDS_SOURCE_TOOLTIP)

    # -- transport ------------------------------------------------------

    def _frame_count(self):
        if self.encoded is not None:
            return len(self.encoded)
        if self.source is not None:
            return len(self.source)
        return 0

    def step(self, delta):
        self.seek(self.frame_index + delta)

    def seek(self, i):
        n = self._frame_count()
        if n == 0:
            self.frame_index = 0
            self._update_frame_label()
            self._sync_scrub_slider_value()
            return
        self.frame_index = max(0, min(int(i), n - 1))
        self._render()
        self._sync_scrub_slider_value()

    def _sync_scrub_slider_range(self):
        """Range/enabled state follow the frame count - called from
        set_frames() whenever encoded/source (and therefore
        _frame_count()) change."""
        n = self._frame_count()
        self._scrub_slider.blockSignals(True)
        self._scrub_slider.setRange(0, max(0, n - 1))
        self._scrub_slider.setValue(self.frame_index)
        self._scrub_slider.setEnabled(n > 0)
        self._scrub_slider.blockSignals(False)

    def _sync_scrub_slider_value(self):
        """Slider follows frame_index - called from seek() (which is
        also what step()/playback/_on_timer ultimately call), so drag/
        click on the slider and programmatic seeks stay in sync in both
        directions. blockSignals prevents this from re-triggering
        _on_scrub_slider_changed -> seek() -> here in a loop."""
        self._scrub_slider.blockSignals(True)
        self._scrub_slider.setValue(self.frame_index)
        self._scrub_slider.blockSignals(False)

    def _on_scrub_slider_changed(self, value):
        """User drag/click on the slider (programmatic updates are
        blockSignals()-guarded in _sync_scrub_slider_value/range above,
        so this only fires for real user interaction)."""
        if value != self.frame_index:
            self.seek(value)

    def play(self):
        if self._frame_count() == 0:
            return
        self._playing = True
        period_ms = int(round(1000.0 / self.fps)) if self.fps > 0 else 40
        self._timer.start(max(1, period_ms))
        self._update_play_button()

    def pause(self):
        self._playing = False
        self._timer.stop()
        self._update_play_button()

    def toggle_play(self):
        if self._playing:
            self.pause()
        else:
            self.play()

    def stop(self):
        self._stop_playback()
        self.seek(0)

    def _stop_playback(self):
        self._playing = False
        self._timer.stop()
        self._update_play_button()

    def _on_timer(self):
        n = self._frame_count()
        if n == 0:
            self.pause()
            return
        if self.frame_index + 1 >= n:
            if self._loop_checkbox.isChecked():
                self.seek(0)
            else:
                self.pause()
        else:
            self.seek(self.frame_index + 1)

    def _update_play_button(self):
        self._play_btn.setText("Pause" if self._playing else "Play")

    def _on_scale_toggled(self, checked):
        self.scale = 2 if checked else 1
        self._render()

    # -- segment markers -------------------------------------------------

    def set_in(self):
        self.seg_in = self.frame_index
        self._update_segment_readout()

    def set_out(self):
        self.seg_out = self.frame_index
        self._update_segment_readout()

    def clear(self):
        self.seg_in = None
        self.seg_out = None
        self._update_segment_readout()

    def _on_clear_clicked(self):
        """Clear button handler - the only path that emits cleared().
        See the cleared signal's docstring for why programmatic clear()
        calls (e.g. MainWindow.select_clip) must not emit it."""
        self.clear()
        self.cleared.emit()

    def _update_segment_readout(self):
        if self.seg_in is None and self.seg_out is None:
            text = "segment: -"
        elif self.seg_in is not None and self.seg_out is not None:
            in_s = self.seg_in / self.fps
            out_s = self.seg_out / self.fps
            text = (f"segment: {in_s:.2f}s - {out_s:.2f}s "
                    f"(f{self.seg_in}-f{self.seg_out})")
        else:
            def part(label, frame):
                if frame is None:
                    return f"{label}: -"
                return f"{label}: f{frame} ({frame / self.fps:.2f}s)"
            text = f"{part('in', self.seg_in)}  {part('out', self.seg_out)}"
        self._segment_label.setText(text)

    def segment_times(self, fps):
        if self.seg_in is None or self.seg_out is None:
            return None
        if self.seg_out <= self.seg_in:
            return None
        fps = float(fps)
        return (self.seg_in / fps, (self.seg_out - self.seg_in) / fps)

    # -- rendering -----------------------------------------------------

    def _current_display_frame(self):
        n = self._frame_count()
        if n == 0:
            return None
        i = self.frame_index

        if self.mode == "Heatmap":
            if not self._heatmap_available():
                return None
            return self._heatmap_frame(i)

        if self.mode == "Flicker" and self.showing_source and self.source is not None:
            if i < len(self.source):
                return self.source[i]
            return None

        if self.encoded is not None and i < len(self.encoded):
            return self.encoded[i]
        if self.source is not None and i < len(self.source):
            return self.source[i]
        return None

    def _heatmap_frame(self, i):
        # encoded/source frame counts are not guaranteed equal (e.g.
        # extraction stopped short of the encode, or vice versa).
        # Heatmap pixels only exist where both sides cover index i;
        # beyond that, fall back to the encoded frame rather than
        # raising or reusing a stale/clamped source index.
        limit = min(len(self.encoded), len(self.source))
        if i >= limit:
            return self.encoded[i] if i < len(self.encoded) else None
        cached = self._heatmap_cache.get(i)
        if cached is not None:
            return cached
        src = self.source[i]
        enc = self.encoded[i]
        frame = diff_heatmap(src, enc)
        if i > 0 and i - 1 < limit:
            mask = stale_bands(self.source[i - 1], src, self.encoded[i - 1], enc,
                                self.column_major)
            frame = self._tint_stale(frame, mask)
        self._heatmap_cache[i] = frame
        return frame

    def _tint_stale(self, frame, mask):
        """40% red tint over stale-band pixels (content the encoder
        deferred, per stale_bands)."""
        out = frame.astype(np.float32)
        tint = np.zeros_like(out)
        tint[..., 0] = 255.0
        for b, stale in enumerate(mask):
            if not stale:
                continue
            sl = (slice(None), slice(b * 4, b * 4 + 4)) if self.column_major \
                else (slice(b * 4, b * 4 + 4),)
            out[sl] = out[sl] * 0.6 + tint[sl] * 0.4
        return np.clip(out, 0, 255).astype(np.uint8)

    def _update_frame_label(self):
        n = self._frame_count()
        self._frame_label.setText(f"frame {self.frame_index}/{n}")

    def _render(self):
        self._update_frame_label()
        frame = self._current_display_frame()
        if frame is None:
            self._image_label.setPixmap(QPixmap())
            return
        arr = np.ascontiguousarray(frame)
        # Keep the buffer alive for as long as the QImage/QPixmap built
        # from it might still be referenced by Qt internals.
        self._last_buffer = arr
        h, w = arr.shape[0], arr.shape[1]
        image = QImage(arr.data, w, h, w * 3, QImage.Format_RGB888)
        pixmap = QPixmap.fromImage(image)
        if self.scale != 1:
            pixmap = pixmap.scaled(w * self.scale, h * self.scale,
                                    Qt.KeepAspectRatio, Qt.FastTransformation)
        self._image_label.setPixmap(pixmap)

    # -- keyboard --------------------------------------------------------

    def keyPressEvent(self, event):
        if event.key() == Qt.Key_Space:
            if self.mode == "Flicker":
                self.toggle_flicker()
            else:
                self.toggle_play()
            event.accept()
            return
        super().keyPressEvent(event)
