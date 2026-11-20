"""CSpect run helpers shared by the XBN checks: card staging, boot, input-editor
readiness and line submission. Waits poll the guest's frame counter and lock bytes."""
import pathlib, shutil, sys, tempfile

ROOT = pathlib.Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "tests"))
from cspect import Session  # noqa: E402

NEX = ROOT / "build" / "nextdaad.nex"
MAP = ROOT / "build" / "nextdaad.map"
TM_MAP = 0x6000
READY_TIMEOUT_S = 30.0
READY_CONFIRM_FRAMES = 5    # the (more, wrap) pair also holds inside SM32; frames rule that out
SUBMIT_SETTLE_FRAMES = 10   # ENTER must be consumed before the locks mean "ready" again
FRAME_TIMEOUT_S = 30.0


def stage_card(leg, xbn=None):
    """Copy leg and the built interpreter to a temp card; xbn replaces GAME.XBN.
    Returns (workdir, card); the caller removes workdir."""
    work = pathlib.Path(tempfile.mkdtemp(prefix="xbn-"))
    card = work / "sd"
    shutil.copytree(leg, card)
    if xbn is not None:
        shutil.copyfile(xbn, card / "GAME.XBN")
    shutil.copyfile(NEX, card / "nextdaad.nex")
    return work, card


def boot(card):
    return Session.boot(card, card / "nextdaad.nex", MAP)


def _locks(s):
    a, b = s.sym("MORELOCK"), s.sym("WRAPLOCK")
    return s.read(a, 1)[0] != 0, s.read(b, 1)[0] != 0


def wait_ready(s):
    """Input editor ready: moreLock and wrapLock set on two reads READY_CONFIRM_FRAMES apart."""
    def ready():
        state = _locks(s)
        if state == (True, False):
            raise SystemExit("parked on a MORE page - more than a page before the prompt")
        if state != (True, True):
            return False
        s.wait_frames(READY_CONFIRM_FRAMES, FRAME_TIMEOUT_S)
        return _locks(s) == (True, True)
    s.wait_until(ready, READY_TIMEOUT_S, what="the input editor")


def disarm_input_timeout(s):
    """Zero inpTOFrames (zero reads as disarmed)."""
    s.write(s.sym("INPTOFRAMES"), b"\x00\x00")


def submit(s, text):
    """Type text and ENTER, return once the editor is ready again."""
    if text:
        s.type_text(text)
        s.wait_frames(2, FRAME_TIMEOUT_S)
    s.enter()
    s.wait_frames(SUBMIT_SETTLE_FRAMES, FRAME_TIMEOUT_S)
    wait_ready(s)
