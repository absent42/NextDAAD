"""CSpect MCP client: JSON-RPC over POST http://127.0.0.1:<port>/mcp. Replies are plain JSON
or SSE (last `data:` line); a Mcp-Session-Id header is sent back once given."""
import http.client
import json
import re
import urllib.error
import urllib.request
from pathlib import Path

CHUNK = 4096                 # bytes per read_memory / write_memory call
INIT_PARAMS = {"protocolVersion": "2025-03-26", "capabilities": {},
               "clientInfo": {"name": "nextdaad-harness", "version": "1"}}


class CSpectError(Exception):
    pass


def read_map(path) -> dict[str, tuple[int, int, int]]:
    """sjasmplus CSPECTMAP file -> {NAME: (16-bit value, CSpect physical, type)}.

    Type 0 is a label (physical = page * $2000 + offset), 1 an EQU, 2 a DEFL. sjasmplus upper-cases
    names; a case-only twin resolves to its label whatever the line order. Malformed or empty raises."""
    out = {}
    for n, line in enumerate(Path(path).read_text(encoding="ascii").splitlines(), 1):
        parts = line.split()
        if not parts:
            continue
        try:
            if len(parts) != 4:
                raise ValueError
            sym = (int(parts[0], 16), int(parts[1], 16), int(parts[2], 16))
        except ValueError:
            raise CSpectError(f"{path}:{n}: not 'value physical type NAME': {line!r}") from None
        name = parts[3].upper()
        if sym[2] == 0 or out.get(name, (0, 0, 1))[2] != 0:
            out[name] = sym
    if not out:
        raise CSpectError(f"{path}: no symbols")
    return out


def parse_dump(text: str, addr: int, n: int) -> bytes:
    """Bytes from a read_memory hex dump: lines of `$addr  b0 .. b15  ascii`."""
    out = bytearray()
    for line in text.splitlines():
        parts = line.split()
        if not parts or not parts[0].startswith("$"):
            continue
        if not re.fullmatch(r"\$[0-9A-Fa-f]+", parts[0]):
            raise CSpectError(f"dump line address is not hex: {line!r}")
        if int(parts[0][1:], 16) != addr + len(out):
            raise CSpectError(f"dump line out of order (wanted ${addr + len(out):X}): {line!r}")
        k = min(16, n - len(out))
        for tok in parts[1:1 + k]:
            if not re.fullmatch(r"[0-9A-Fa-f]{2}", tok):
                raise CSpectError(f"dump line has {tok!r} where a byte belongs: {line!r}")
            out.append(int(tok, 16))
    if len(out) != n:
        raise CSpectError(f"dump has {len(out)} bytes, wanted {n}")
    return bytes(out)


def decode_reply(body: str) -> dict:
    """One JSON-RPC reply from a plain JSON body or an SSE body (last `data:` line)."""
    data = [line[5:].strip() for line in body.splitlines() if line.startswith("data:")]
    payload = data[-1] if data else body.strip()
    if not payload:
        raise CSpectError("empty MCP reply")
    try:
        reply = json.loads(payload)
    except json.JSONDecodeError as e:
        raise CSpectError(f"MCP reply is not JSON: {payload[:200]!r}") from e
    if not isinstance(reply, dict):
        raise CSpectError(f"MCP reply is not an object: {payload[:200]!r}")
    return reply


class Mcp:
    """JSON-RPC over HTTP to one CSpect MCP server."""

    def __init__(self, port: int):
        self.port = port
        self.url = f"http://127.0.0.1:{port}/mcp"
        self.session = None
        self._id = 0

    def rpc(self, method: str, params: dict | None = None, timeout: float = 150) -> dict:
        """The reply's result; a JSON-RPC error or a transport failure raises CSpectError."""
        self._id += 1
        body = json.dumps({"jsonrpc": "2.0", "id": self._id, "method": method,
                           "params": params or {}}).encode()
        headers = {"Content-Type": "application/json",
                   "Accept": "application/json, text/event-stream"}
        if self.session:
            headers["Mcp-Session-Id"] = self.session
        req = urllib.request.Request(self.url, data=body, headers=headers)
        try:
            with urllib.request.urlopen(req, timeout=timeout) as r:
                self.session = r.headers.get("Mcp-Session-Id") or self.session
                text = r.read().decode("utf-8", "replace")
        except (urllib.error.URLError, OSError, http.client.HTTPException) as e:
            raise CSpectError(f"{method} on port {self.port}: {type(e).__name__}: {e}") from e
        reply = decode_reply(text)
        if "error" in reply:
            raise CSpectError(f"{method}: {reply['error']}")
        if reply.get("id") != self._id or "result" not in reply:
            raise CSpectError(f"{method}: reply is not the result of request {self._id}: {text[:200]!r}")
        return reply["result"]

    def initialize(self, timeout: float = 150) -> dict:
        return self.rpc("initialize", INIT_PARAMS, timeout=timeout)

    def call(self, tool: str, **args) -> dict:
        """tools/call; returns the result ({"content": [...]}); a tool error raises CSpectError."""
        res = self.rpc("tools/call", {"name": tool, "arguments": args})
        if res.get("isError"):
            raise CSpectError(f"{tool} {args}: {self.text(res)}")
        return res

    @staticmethod
    def text(result: dict) -> str:
        return "\n".join(c["text"] for c in result.get("content", []) if c.get("type") == "text")

    def tools(self) -> list[dict]:
        """Every tool's name and inputSchema (follows nextCursor pages)."""
        out, params = [], {}
        while True:
            res = self.rpc("tools/list", params)
            if not isinstance(res.get("tools"), list):
                raise CSpectError(f"tools/list reply has no 'tools' list: {str(res)[:200]}")
            for t in res["tools"]:
                if not isinstance(t, dict) or "name" not in t:
                    raise CSpectError(f"tools/list entry has no 'name': {str(t)[:200]}")
                out.append({"name": t["name"], "inputSchema": t.get("inputSchema", {})})
            if not res.get("nextCursor"):
                return out
            params = {"cursor": res["nextCursor"]}

    def read(self, addr: int, n: int, physical: bool = False) -> bytes:
        """n bytes from the Z80's 64K view, or from CSpect's physical view with physical=True."""
        out = bytearray()
        while len(out) < n:
            k = min(CHUNK, n - len(out))
            a = addr + len(out)
            res = self.call("read_memory", address=f"${a:X}", length=k, physical=physical)
            out += parse_dump(self.text(res), a, k)
        return bytes(out)

    def write(self, addr: int, data: bytes, physical: bool = False) -> None:
        for i in range(0, len(data), CHUNK):
            self.call("write_memory", address=f"${addr + i:X}", data=data[i:i + CHUNK].hex(),
                      physical=physical)

    def status(self) -> str:
        return self.text(self.call("get_status"))

    def pc(self) -> int:
        text = self.status()
        m = re.search(r"\bPC \$([0-9A-Fa-f]{4})\b", text)
        if not m:
            raise CSpectError(f"get_status has no PC $xxxx: {text[:200]!r}")
        return int(m.group(1), 16)
