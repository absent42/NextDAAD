"""Python ioctl smoke: one two-transfer SPI_IOC_MESSAGE, header at 2 MHz then 64 bytes at
4 MHz, through SpidevLink(py_ioctl=True). Needs no Next; proves the spi_ioc_transfer layout.
"""
import errno
import os
import sys

import link as lk
import pi303_probe as probe

TOOL = "pi303_smoke"
PAYLOAD = 64
SMOKE_HZ = 4_000_000


def _wrap_ioctl(fcntl, state):
    orig = fcntl.ioctl

    def wrapped(fd, req, arg=0, *a):
        try:
            state["ret"] = orig(fd, req, arg, *a)
        except OSError as e:
            state["err"] = e.errno or errno.EIO
            raise
        return state["ret"]
    fcntl.ioctl = wrapped
    return orig


def main(link, out_dir, bundle, core_clk=None, spi_open=None, **_):
    spi_open = spi_open or probe.default_spi_open
    header = lk.build_header(lk.CMD_SRAM_R, 0, PAYLOAD)
    total = len(header) + PAYLOAD
    import fcntl
    state = {}
    orig = _wrap_ioctl(fcntl, state)
    skip = False
    try:
        try:
            link.xfer(header, b"", PAYLOAD, SMOKE_HZ)
        except (OSError, lk.LinkError):
            pass
    finally:
        fcntl.ioctl = orig
    if "err" in state:
        ret = -state["err"]
    elif isinstance(state.get("ret"), int):
        ret = 0 if state["ret"] == total else state["ret"]
    else:
        ret, skip = -1, True        # no ioctl result: the link failed before or around it
    ok = int(not skip and "err" not in state and ret == 0)
    log = probe.open_log(os.path.join(out_dir, "SMOKE.LOG"), TOOL, bundle, link, None, 0,
                         None, spi_open())
    try:
        if skip:
            log.skip("P2PY", "LINK")
        log.row("P2PY", ok=ok, ret=ret)
    finally:
        log.close()
    return 0 if ok else 1


def cli(link_factory, argv=None, clock=None, **kw):
    return probe.run_cli(TOOL, "SMOKE.LOG", main, link_factory, argv, clock, **kw)


if __name__ == "__main__":
    sys.exit(cli(lambda: lk.SpidevLink(py_ioctl=True)))
