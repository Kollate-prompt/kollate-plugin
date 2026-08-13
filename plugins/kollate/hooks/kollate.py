#!/usr/bin/env python3
"""Everything the plugin does with a transcript: read the delta, compact it, deliver it.

Design notes that matter, all of them from PHASE-A-SPEC.md:

* The trigger is `Stop`, which fires **every turn**, not `SessionEnd`. So each delivery is a
  delta - the part of the transcript above the watermark - and is usually one turn.
* The watermark advances **only on a confirmed 2xx** (§2.3.0). Anything else and we leave it
  where it is, so the next turn re-sends the same range. Re-delivery is safe because the
  server dedups on (conversation_id, seq).
* `seq` continues across deliveries. It is the message's identity and its read order, so it
  is stored in the watermark alongside the byte offset.
* Nothing here ever puts a token in argv - `ps` is readable by every user on the machine.
"""

from __future__ import annotations

import hashlib
import hmac
import json
import os
import subprocess
import sys
import time
import urllib.parse

# One delivery is capped server-side at 10 MB. Stay under it with room to spare, and split
# a large delta across several deliveries rather than failing forever on one oversized turn.
MAX_DELIVERY_BYTES = 8 * 1024 * 1024
CONNECT_TIMEOUT_SECONDS = 15


# --------------------------------------------------------------------------- paths / state


def plugin_dir() -> str:
    return os.environ.get("CLAUDE_PLUGIN_DATA") or os.path.expanduser("~/.kollate")


def watermark_path() -> str:
    return os.path.join(plugin_dir(), "delivered.json")


def credentials_path() -> str:
    return os.path.join(plugin_dir(), "credentials.json")


def read_json(path: str, default):
    try:
        with open(path, encoding="utf-8") as handle:
            return json.load(handle)
    except Exception:
        return default


def write_json_private(path: str, value) -> None:
    """Write owner-only, and atomically - a half-written watermark would re-send the world."""
    os.makedirs(os.path.dirname(path), mode=0o700, exist_ok=True)
    tmp = f"{path}.tmp"
    fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    with os.fdopen(fd, "w", encoding="utf-8") as handle:
        json.dump(value, handle)
    os.replace(tmp, path)


def credentials() -> dict:
    """Stored credential from /kollate:connect, else the no-browser userConfig fallback."""
    stored = read_json(credentials_path(), {})
    token = stored.get("capture_token") or os.environ.get("CLAUDE_PLUGIN_OPTION_CAPTURE_TOKEN", "")
    secret = stored.get("hook_secret") or os.environ.get("CLAUDE_PLUGIN_OPTION_HOOK_SECRET", "")
    endpoint = (
        stored.get("endpoint")
        or os.environ.get("CLAUDE_PLUGIN_OPTION_ENDPOINT")
        or "https://app.kollate.ai"
    )
    return {"capture_token": token, "hook_secret": secret, "endpoint": endpoint.rstrip("/")}


def enrolled_at() -> float:
    """The moment this machine was connected. Older transcripts are never captured (§2.4)."""
    path = os.path.join(plugin_dir(), "enrolled_at")
    try:
        return float(open(path, encoding="utf-8").read().strip())
    except Exception:
        now = time.time()
        os.makedirs(plugin_dir(), mode=0o700, exist_ok=True)
        fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
        with os.fdopen(fd, "w", encoding="utf-8") as handle:
            handle.write(str(now))
        return now


# ----------------------------------------------------------------------------- compaction


def _flatten(content) -> str:
    """Text only. Thinking blocks, images and tool traffic never become stored messages."""
    if isinstance(content, str):
        return content
    if not isinstance(content, list):
        return ""
    parts = []
    for block in content:
        if isinstance(block, dict) and block.get("type") == "text":
            parts.append(block.get("text", ""))
    return "\n".join(part for part in parts if part)


def turns_from(path: str, start_offset: int) -> tuple[list[dict], int]:
    """Read the transcript from `start_offset` and return whole turns plus the new offset.

    The offset only ever advances to the end of the last COMPLETE line: Claude Code may be
    mid-write, and half a JSON object is not a turn. That torn tail is simply read again next
    time, which is the cheapest correct thing to do.
    """
    turns: list[dict] = []
    consumed = start_offset
    try:
        with open(path, "rb") as handle:
            handle.seek(start_offset)
            data = handle.read()
    except OSError:
        return [], start_offset

    for raw in data.splitlines(keepends=True):
        if not raw.endswith(b"\n"):
            # The last line is still being written. Leave it for the next delivery - half a
            # JSON object is not a turn, and re-reading it costs nothing.
            break
        line_length = len(raw)
        if not raw.strip():
            consumed += line_length
            continue
        try:
            record = json.loads(raw.decode("utf-8", "replace"))
        except Exception:
            break
        consumed += line_length

        if record.get("type") not in ("user", "assistant"):
            continue  # mode, attachment, system, snapshot - noise we do not store
        message = record.get("message") or {}
        text = _flatten(message.get("content"))
        if not text:
            continue  # a turn that was only a tool call has nothing readable to store
        turns.append(
            {
                "role": message.get("role") or record.get("type"),
                "content": text,
                "uuid": record.get("uuid"),
                "sent_at": record.get("timestamp"),
            }
        )

    return turns, consumed


def batches(turns: list[dict], first_seq: int):
    """Number the turns and split them so no single delivery approaches the size ceiling."""
    batch: list[dict] = []
    size = 0
    seq = first_seq
    for turn in turns:
        numbered = dict(turn, seq=seq)
        seq += 1
        encoded = len(json.dumps(numbered))
        if batch and size + encoded > MAX_DELIVERY_BYTES:
            yield batch
            batch, size = [], 0
        batch.append(numbered)
        size += encoded
    if batch:
        yield batch


# ------------------------------------------------------------------------------- delivery


def deliver(session_id: str, messages: list[dict], creds: dict, title: str | None = None) -> bool:
    """POST one delta. True only on a confirmed 2xx - that is what moves the watermark."""
    payload = {"session_id": session_id, "messages": messages}
    if title:
        payload["title"] = title
    body = json.dumps(payload, ensure_ascii=False)
    timestamp = str(int(time.time()))
    signature = hmac.new(
        creds["hook_secret"].encode(), f"{timestamp}.{body}".encode(), hashlib.sha256
    ).hexdigest()

    # curl reads the Authorization header from stdin via --config, so the token never appears
    # in argv. The body goes to a private temp file for the same reason.
    config = (
        f'header = "Authorization: Bearer {creds["capture_token"]}"\n'
        f'header = "x-kollate-signature: {signature}"\n'
        f'header = "x-kollate-timestamp: {timestamp}"\n'
        'header = "Content-Type: application/json"\n'
    )
    path = os.path.join(plugin_dir(), f".delivery-{os.getpid()}.json")
    fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    with os.fdopen(fd, "w", encoding="utf-8") as handle:
        handle.write(body)

    try:
        result = subprocess.run(
            [
                "curl", "-s", "-o", "/dev/null", "-w", "%{http_code}",
                "--max-time", str(CONNECT_TIMEOUT_SECONDS),
                "-X", "POST", f"{creds['endpoint']}/api/capture",
                "--config", "-",
                "--data-binary", f"@{path}",
            ],
            input=config,
            capture_output=True,
            text=True,
            timeout=CONNECT_TIMEOUT_SECONDS + 5,
        )
        status = (result.stdout or "").strip()
        return status.startswith("2")
    except Exception:
        return False
    finally:
        try:
            os.remove(path)
        except OSError:
            pass


def capture_session(transcript: str, session_id: str) -> None:
    """One session's delta, start to finish. Silent on every failure - it is a hook."""
    creds = credentials()
    if not creds["capture_token"] or not creds["hook_secret"]:
        return
    if not os.path.isfile(transcript):
        return
    # Never capture a transcript that predates enrolment.
    try:
        if os.path.getmtime(transcript) < enrolled_at() and not os.path.getsize(transcript):
            return
    except OSError:
        return

    marks = read_json(watermark_path(), {})
    mark = marks.get(session_id) or {"offset": 0, "next_seq": 0}

    turns, new_offset = turns_from(transcript, int(mark.get("offset", 0)))
    if not turns:
        return

    seq = int(mark.get("next_seq", 0))
    delivered_offset = mark["offset"]
    for batch in batches(turns, seq):
        if not deliver(session_id, batch, creds):
            # Leave the watermark where the last confirmed delivery left it. The next turn
            # re-sends from there, and the server dedups. Nothing is lost, nothing doubles.
            break
        seq = batch[-1]["seq"] + 1
        delivered_offset = new_offset
        marks[session_id] = {"offset": delivered_offset, "next_seq": seq}
        write_json_private(watermark_path(), marks)


def reconcile(live_session_id: str) -> None:
    """Crash recovery (§2.3.1): a watermark scan, not a spool drain.

    A crash means no Stop hook ever ran, so nothing was ever spooled. What we do have is the
    watermark - any transcript longer than the last confirmed delivery has unsent turns in it.
    """
    creds = credentials()
    if not creds["capture_token"]:
        return
    marks = read_json(watermark_path(), {})
    cutoff = enrolled_at()
    root = os.path.expanduser("~/.claude/projects")
    for directory, _subdirs, files in os.walk(root):
        for name in files:
            if not name.endswith(".jsonl"):
                continue
            session_id = name[:-6]
            if session_id == live_session_id:
                continue  # the running session belongs to the Stop hook
            path = os.path.join(directory, name)
            try:
                if os.path.getmtime(path) < cutoff:
                    continue  # older than enrolment - never ours to take (§2.4)
                if os.path.getsize(path) <= int((marks.get(session_id) or {}).get("offset", 0)):
                    continue  # nothing new since the last confirmed delivery
            except OSError:
                continue
            capture_session(path, session_id)


# ----------------------------------------------------------------------------------- main


def read_event(timeout_seconds: float = 2.0) -> dict:
    """Read the hook payload from stdin, refusing to block the person's turn on it.

    `select` rather than a `timeout` command, because `timeout` does not exist on macOS -
    which is most of the people this runs for.
    """
    import select

    try:
        ready, _, _ = select.select([sys.stdin], [], [], timeout_seconds)
        if not ready:
            return {}
        return json.loads(sys.stdin.read() or "{}")
    except Exception:
        return {}


def detach(work, worker_command: str, event: dict) -> None:
    """Run `work` behind the session and return immediately.

    `fork` rather than spawning a second interpreter: the Stop hook sits between the person
    and their next prompt, and starting Python twice costs more than the whole budget for it
    (work order §02.4 - under 50 ms, every round). Windows has no fork, so it falls back to
    a detached child there.
    """
    if hasattr(os, "fork"):
        if os.fork() != 0:
            return  # parent: done, get out of the way
        os.setsid()
        try:
            null = os.open(os.devnull, os.O_RDWR)
            for stream in (0, 1, 2):
                os.dup2(null, stream)
            work()
        finally:
            os._exit(0)

    path = os.path.join(plugin_dir(), f".event-{os.getpid()}.json")
    os.makedirs(plugin_dir(), mode=0o700, exist_ok=True)
    fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    with os.fdopen(fd, "w", encoding="utf-8") as handle:
        json.dump(event, handle)
    subprocess.Popen(
        [sys.executable, os.path.abspath(__file__), worker_command, path],
        stdin=subprocess.DEVNULL,
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
        start_new_session=True,
    )


def main() -> int:
    command = sys.argv[1] if len(sys.argv) > 1 else "capture"

    if command == "capture":
        event = read_event()
        transcript = event.get("transcript_path") or event.get("transcriptPath") or ""
        session_id = event.get("session_id") or event.get("sessionId") or ""
        if not transcript or not session_id:
            return 0
        detach(lambda: capture_session(transcript, session_id), "capture-worker", event)
        return 0

    if command == "capture-worker":
        event = read_json(sys.argv[2], {})
        try:
            os.remove(sys.argv[2])
        except OSError:
            pass
        transcript = event.get("transcript_path") or event.get("transcriptPath") or ""
        session_id = event.get("session_id") or event.get("sessionId") or ""
        if not transcript or not session_id:
            return 0
        capture_session(transcript, session_id)
        return 0

    if command == "reconcile":
        event = read_event()
        live = event.get("session_id") or event.get("sessionId") or ""
        detach(lambda: reconcile(live), "reconcile-worker", event)
        return 0

    if command == "reconcile-worker":
        event = read_json(sys.argv[2], {}) if len(sys.argv) > 2 else {}
        try:
            if len(sys.argv) > 2:
                os.remove(sys.argv[2])
        except OSError:
            pass
        reconcile(event.get("session_id") or event.get("sessionId") or "")
        return 0

    if command == "connect":
        return connect()

    return 0


# ---------------------------------------------------------------------------- the connect


def connect() -> int:
    """Loopback sign-in. The person sees their normal Kollate login and nothing else."""
    import http.server
    import socket
    import threading
    import webbrowser

    endpoint = (
        os.environ.get("CLAUDE_PLUGIN_OPTION_ENDPOINT") or "https://app.kollate.ai"
    ).rstrip("/")

    probe = socket.socket()
    probe.bind(("127.0.0.1", 0))
    port = probe.getsockname()[1]
    probe.close()

    redirect_uri = f"http://127.0.0.1:{port}/callback"
    state = hashlib.sha256(os.urandom(32)).hexdigest()[:32]
    received: dict[str, str] = {}

    class Handler(http.server.BaseHTTPRequestHandler):
        def do_GET(self):  # noqa: N802 - stdlib naming
            query = urllib.parse.parse_qs(urllib.parse.urlparse(self.path).query)
            received.update({k: v[0] for k, v in query.items()})
            self.send_response(200)
            self.send_header("Content-Type", "text/html; charset=utf-8")
            self.end_headers()
            self.wfile.write(b"<h2>Connected. You can close this tab.</h2>")

        def log_message(self, *args):  # keep the terminal clean
            pass

    server = http.server.HTTPServer(("127.0.0.1", port), Handler)
    server.timeout = 180
    thread = threading.Thread(target=server.handle_request, daemon=True)
    thread.start()

    label = f"{os.uname().nodename}"
    url = (
        f"{endpoint}/connect-machine?redirect_uri={urllib.parse.quote(redirect_uri, safe='')}"
        f"&state={state}&label={urllib.parse.quote(label, safe='')}"
    )
    print("Opening your browser to sign in to Kollate...")
    if not webbrowser.open(url):
        print(f"Open this link to finish connecting:\n  {url}")

    thread.join(timeout=185)
    if received.get("state") != state or not received.get("code"):
        print("Sign-in did not complete. Nothing was changed.")
        return 1

    exchange = json.dumps({"code": received["code"], "redirect_uri": redirect_uri, "label": label})
    try:
        result = subprocess.run(
            [
                "curl", "-s", "--max-time", "20",
                "-X", "POST", f"{endpoint}/api/connect/exchange",
                "-H", "Content-Type: application/json",
                "--data-binary", "@-",
            ],
            input=exchange,
            capture_output=True,
            text=True,
            timeout=30,
        )
        issued = json.loads(result.stdout or "{}")
    except Exception:
        issued = {}

    if not issued.get("capture_token") or not issued.get("hook_secret"):
        print("Could not complete the connection. Nothing was changed.")
        return 1

    # Replace any previous credential in place, so connecting twice does not leave two
    # machines behind. Owner-only, and it lives in CLAUDE_PLUGIN_DATA so a plugin update
    # does not take it with it.
    write_json_private(
        credentials_path(),
        {
            "capture_token": issued["capture_token"],
            "hook_secret": issued["hook_secret"],
            "connection_id": issued.get("connection_id"),
            "endpoint": endpoint,
        },
    )
    enrolled_at()
    print("Connected. New Claude Code conversations on this machine will be saved to Kollate.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
