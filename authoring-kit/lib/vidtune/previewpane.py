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
    QVBoxLayout,
    QWidget,
)

from .preview import decode_vid, diff_heatmap, stale_bands

DEFAULT_FPS = 25.0
MODES = ("Encoded", "Flicker", "Heatmap")


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


class PreviewPane(QWidget):
    """Encoded/Flicker/Heatmap preview with transport controls and
    in/out segment markers (frame indices, converted to seconds for
    the encoder's --start/--duration via segment_times())."""

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
        self.scale = 1
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
            btn.clicked.connect(lambda checked=False, n=name: self.set_mode(n))
            mode_group.addButton(btn)
            mode_row.addWidget(btn)
            self._mode_buttons[name] = btn
        self._mode_buttons["Encoded"].setChecked(True)

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
        self._clear_btn.clicked.connect(self.clear)
        self._scale_btn = QPushButton("2x")
        self._scale_btn.setCheckable(True)
        self._scale_btn.toggled.connect(self._on_scale_toggled)

        transport_row = QHBoxLayout()
        for w in (self._play_btn, self._stop_btn, self._step_back_btn,
                  self._step_fwd_btn, self._loop_checkbox, self._frame_label,
                  self._set_in_btn, self._set_out_btn, self._clear_btn,
                  self._scale_btn):
            transport_row.addWidget(w)
        transport_row.addStretch(1)

        outer = QVBoxLayout(self)
        outer.addWidget(self._busy_label)
        outer.addWidget(self._error_label)
        outer.addWidget(self._hint_label)
        outer.addWidget(self._image_label, 1)
        outer.addLayout(mode_row)
        outer.addLayout(transport_row)

        self._update_mode_buttons()

    # -- frame injection / loading ----------------------------------

    def set_frames(self, encoded, source, fps, column_major):
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
        self._update_mode_buttons()
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

    def _show_busy(self, busy):
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
        if name == "Heatmap" and not self._heatmap_available():
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
        self._mode_buttons["Heatmap"].setEnabled(self._heatmap_available())

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
            return
        self.frame_index = max(0, min(int(i), n - 1))
        self._render()

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

    def set_out(self):
        self.seg_out = self.frame_index

    def clear(self):
        self.seg_in = None
        self.seg_out = None

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
