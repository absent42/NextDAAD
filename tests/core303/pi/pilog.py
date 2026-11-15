"""Writer for the #PI303 log grammar (LF endings, ASCII). Parsed by tests/core303/parse.py."""
import re

_KEY = re.compile(r"[a-z][a-z0-9_]*\Z")
_TAG = re.compile(r"[A-Z0-9]{4}\Z")
_BARE = re.compile(r"[\x21-\x7E]*\Z")


class PiLogWriter:
    def __init__(self, path, tool, bundle):
        if not re.fullmatch(r"[\x21-\x7E]+", tool):
            raise ValueError("bad tool %r" % tool)
        if not re.fullmatch(r"[0-9a-f]{12}", bundle):
            raise ValueError("bad bundle %r" % bundle)
        self._f = open(path, "w", encoding="ascii", newline="\n")
        self._rows = 0
        self._closed = False
        self._line("#PI303 %s %s" % (tool, bundle))

    def _line(self, text):
        self._f.write(text + "\n")
        self._f.flush()

    @staticmethod
    def _kv(kv, fmt):
        out = []
        for k, v in kv.items():
            if not _KEY.match(k):
                raise ValueError("bad key %r" % k)
            out.append("%s=%s" % (k, fmt(v)))
        return " ".join(out)

    def env(self, **kv):
        def fmt(v):
            s = str(v)
            if not _BARE.match(s):
                raise ValueError("bad #PIENV value %r" % s)
            return s
        self._line("#PIENV " + self._kv(kv, fmt))

    def spi(self, version, caps, core_clk, core_clk_src):
        if core_clk_src not in ("debugfs", "none"):
            raise ValueError("bad core_clk_src %r" % core_clk_src)
        self._line("#SPI version=%02X caps=%02X core_clk=%d core_clk_src=%s"
                   % (version, caps, core_clk, core_clk_src))

    def row(self, tag, **kv):
        if not _TAG.match(tag):
            raise ValueError("bad tag %r" % tag)
        if not kv:
            raise ValueError("row without fields")
        for v in kv.values():
            if isinstance(v, bool) or not isinstance(v, int):
                raise ValueError("non-integer value %r" % (v,))
        self._line(tag + " " + self._kv(kv, str))
        self._rows += 1

    def skip(self, tag, reason):
        if not _TAG.match(tag) or not reason or "\n" in reason:
            raise ValueError("bad skip %r %r" % (tag, reason))
        self._line("#SKIP %s %s" % (tag, reason))

    def close(self):
        if self._closed:
            return
        self._closed = True
        self._line("#END %04X" % self._rows)
        self._f.close()
