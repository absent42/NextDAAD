"""openMSX `-control stdio` client (XML command protocol), headless.

Launched with renderer none and a null sound driver from a settings file
written beside the run; every reply is the next <reply> element on stdout.
"""
import re
import subprocess
import threading
import queue
from pathlib import Path
from xml.sax.saxutils import escape

SETTINGS = """<?xml version="1.0"?>
<!DOCTYPE settings SYSTEM 'settings.dtd'>
<settings>
  <settings>
    <setting id="renderer">none</setting>
    <setting id="sound_driver">null</setting>
  </settings>
</settings>
"""

_REPLY = re.compile(r'<reply result="(ok|nok)">(.*?)</reply>', re.S)


def _unescape(s):
    s = re.sub(r"&#x([0-9a-fA-F]+);", lambda m: chr(int(m.group(1), 16)), s)
    s = re.sub(r"&#([0-9]+);", lambda m: chr(int(m.group(1))), s)
    return (s.replace("&lt;", "<").replace("&gt;", ">")
            .replace("&quot;", '"').replace("&apos;", "'")
            .replace("&amp;", "&"))


class OpenMsx:
    def __init__(self, exe, args, cwd, settings_path):
        Path(settings_path).write_text(SETTINGS, encoding="utf-8")
        cmd = [str(exe), "-control", "stdio", "-setting",
               str(settings_path)] + list(args)
        self.cmdline = cmd
        self.p = subprocess.Popen(cmd, cwd=str(cwd), stdin=subprocess.PIPE,
                                  stdout=subprocess.PIPE,
                                  stderr=subprocess.DEVNULL)
        self.q = queue.Queue()
        self.buf = ""
        self.log = []
        threading.Thread(target=self._reader, daemon=True).start()
        self.p.stdin.write(b"<openmsx-control>\n")
        self.p.stdin.flush()

    def _reader(self):
        while True:
            b = self.p.stdout.read1(65536)
            if not b:
                self.q.put(None)
                return
            self.q.put(b.decode("latin-1"))

    def cmd(self, tcl, timeout=30.0):
        """Run one Tcl command; returns its result, raises on nok."""
        self.p.stdin.write(("<command>%s</command>\n" % escape(tcl))
                           .encode("latin-1"))
        self.p.stdin.flush()
        while True:
            m = _REPLY.search(self.buf)
            if m:
                pre = self.buf[:m.start()]
                if pre.strip():
                    self.log.append(pre)
                self.buf = self.buf[m.end():]
                res = _unescape(m.group(2))
                if m.group(1) == "nok":
                    raise RuntimeError("openMSX: %s -> %s" % (tcl, res))
                return res
            chunk = self.q.get(timeout=timeout)
            if chunk is None:
                raise RuntimeError("openMSX exited, rc=%s" % self.p.poll())
            self.buf += chunk

    def kill(self):
        try:
            self.p.kill()
            self.p.wait(timeout=10)
        except Exception:
            pass
        return self.p.poll()
