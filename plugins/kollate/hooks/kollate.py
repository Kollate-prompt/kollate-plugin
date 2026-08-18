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
import html
import json
import os
import subprocess
import sys
import time
import urllib.parse

# The server refuses anything over 4 MB. Split well under it rather than failing forever on
# one oversized turn.
MAX_DELIVERY_BYTES = 3 * 1024 * 1024
CONNECT_TIMEOUT_SECONDS = 15
# Backfill is bounded: the machines we measured held 378 old sessions and 1.1 GB.
BACKFILL_DEFAULT_LIMIT = 20
BACKFILL_MAX_LIMIT = 200
# How long the detached worker waits for the finished turn to be flushed to the transcript.
SETTLE_SECONDS = 0.75


# --------------------------------------------------------------------------- paths / state


def plugin_dir() -> str:
    return os.environ.get("CLAUDE_PLUGIN_DATA") or os.path.expanduser("~/.kollate")


def shared_dir() -> str:
    """One place both surfaces can see.

    Claude Code in a terminal sets CLAUDE_PLUGIN_DATA; the desktop app may not, and it has no
    userConfig screen at all - its plugin page shows only Skills and Hooks. So the address and
    the credential are also kept here, where either surface finds them, and connecting once is
    enough for both.
    """
    return os.path.expanduser("~/.kollate")


def configured_endpoint() -> str:
    """Where this organisation's Kollate lives, from whichever surface could tell us.

    userConfig is the documented route and works in the terminal. It is simply absent on the
    desktop app, so a file the installer writes has to serve there - otherwise the plugin can
    never learn its own address and connect fails with nothing the person can do about it.
    """
    from_env = (os.environ.get("CLAUDE_PLUGIN_OPTION_ENDPOINT") or "").strip()
    if from_env:
        return from_env.rstrip("/")
    for directory in (plugin_dir(), shared_dir()):
        stored = read_json(os.path.join(directory, "config.json"), {})
        value = str(stored.get("endpoint") or "").strip()
        if value:
            return value.rstrip("/")
    return ""


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


def printable(value: str, limit: int = 200) -> str:
    """Text from outside, made safe to print.

    Escape sequences in a terminal can move the cursor, recolour, or overwrite what is already
    on screen - so a message that arrives on a URL must not be echoed verbatim, however
    trustworthy the sender looks.
    """
    cleaned = "".join(character for character in value if character.isprintable())
    return cleaned.strip()[:limit]


def safe_api_base(value: str) -> str:
    """Accept a delivery address only if it is one we would be willing to send a token to.

    This value decides where conversations and a bearer token get posted, and it arrives from
    outside: a query parameter on the loopback callback, or a setup key somebody was handed.
    The callback is already gated on a 128-bit `state` the caller cannot guess, but a value
    that steers where secrets go should not rest on one check alone.

    Returns "" for anything untrusted, which every caller treats as "do not deliver".
    """
    if not value:
        return ""
    try:
        parsed = urllib.parse.urlparse(value)
    except Exception:
        return ""

    host = (parsed.hostname or "").rstrip(".").lower()
    if not host or parsed.username or parsed.password or parsed.query or parsed.fragment:
        return ""

    # Loopback over http is for running the checks against a local stack. Nothing else may
    # be plaintext: a delivery address is where a bearer token goes.
    if host in ("127.0.0.1", "::1", "localhost"):
        return value.rstrip("/") if parsed.scheme == "http" else ""
    if parsed.scheme != "https":
        return ""
    return value.rstrip("/")


def unpack_machine_key(value: str) -> dict:
    """Decode the single setup key pasted into a machine with no browser.

    It carries the token, the signing secret and the connection id together, so somebody on
    an SSH session copies one value instead of three in the right order.
    """
    import base64

    if not value.startswith("kollate_"):
        return {}
    try:
        raw = value[len("kollate_") :]
        padded = raw + "=" * (-len(raw) % 4)
        decoded = json.loads(base64.urlsafe_b64decode(padded.encode()).decode())
        return {
            "capture_token": decoded.get("t", ""),
            "hook_secret": decoded.get("s", ""),
            "connection_id": decoded.get("c"),
            "api_base": safe_api_base(decoded.get("a", "")),
        }
    except Exception:
        return {}


def credentials() -> dict:
    """Stored credential from /kollate:connect, else the no-browser setup key."""
    stored = read_json(credentials_path(), {})
    if not stored.get("capture_token"):
        # Connected from the other surface on this same machine.
        stored = read_json(os.path.join(shared_dir(), "credentials.json"), {})
    pasted = unpack_machine_key(os.environ.get("CLAUDE_PLUGIN_OPTION_CAPTURE_TOKEN", "").strip())
    token = stored.get("capture_token") or pasted.get("capture_token", "")
    secret = stored.get("hook_secret") or pasted.get("hook_secret", "")
    endpoint = stored.get("endpoint") or configured_endpoint()
    api = safe_api_base(stored.get("api_base") or "") or pasted.get("api_base") or ""
    return {
        "capture_token": token,
        "hook_secret": secret,
        "endpoint": endpoint.rstrip("/"),
        # Deliveries go to Supabase, not to the frontend. Learned at connect time.
        "api_base": api or safe_api_base(endpoint),
    }


def pause_path() -> str:
    # Shared, deliberately: pausing from the terminal must also pause the desktop app.
    return os.path.join(shared_dir(), "pause.json")


def capture_blocked(session_id: str) -> str:
    """Why capture is off right now, or "" when it is on.

    Paused turns are DROPPED, not held: "don't capture this" means the content must never
    arrive, and a queue that flushes on resume would deliver exactly what the person asked
    to keep out.
    """
    state = read_json(pause_path(), {})
    if session_id and session_id in (state.get("sessions") or []):
        return "this session is paused"
    if "until" in state:
        if state["until"] is None:
            return "capture is stopped"
        try:
            if time.time() < float(state["until"]):
                return "capture is paused"
        except (TypeError, ValueError):
            pass
    return ""


def cmd_pause(scope: str) -> int:
    state = read_json(pause_path(), {})
    now = time.time()
    if scope in ("session", "this session", "this"):
        sid = os.environ.get("CLAUDE_CODE_SESSION_ID", "").strip()
        if not sid:
            print("Could not tell which session this is. Use a duration instead: /kollate:pause 3h")
            return 1
        sessions = set(state.get("sessions") or [])
        sessions.add(sid)
        state["sessions"] = sorted(sessions)
        message = "Paused: this session will not be captured. Everything else still is."
    elif scope in ("3h", "3 hours", "3hours"):
        state["until"] = now + 3 * 3600
        message = "Capture paused for 3 hours. Nothing on this machine is captured until then."
    elif scope == "today":
        local = time.localtime(now)
        midnight = time.mktime((local.tm_year, local.tm_mon, local.tm_mday, 23, 59, 59, 0, 0, -1))
        state["until"] = midnight
        message = "Capture paused for the rest of today."
    elif scope in ("week", "1w", "7d"):
        state["until"] = now + 7 * 86400
        message = "Capture paused for a week."
    elif scope in ("stop", "forever", "off"):
        state["until"] = None
        message = "Capture stopped on this machine. /kollate:resume turns it back on."
    else:
        print("Pause what? One of: session · 3h · today · week   (or /kollate:stop)")
        return 1
    write_json_private(pause_path(), state)
    print(message + " Paused turns are dropped, not queued - they will not arrive later.")
    return 0


def cmd_resume() -> int:
    try:
        os.remove(pause_path())
    except OSError:
        pass
    print("Capture resumed. New turns from now on are captured; nothing from the pause is.")
    return 0


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


def turns_from(path: str, start_offset: int) -> tuple[list[dict], int, str | None, bool]:
    """Read the transcript from `start_offset`: whole turns, the new offset, and a name.

    The offset only ever advances to the end of the last COMPLETE line: Claude Code may be
    mid-write, and half a JSON object is not a turn. That torn tail is simply read again next
    time, which is the cheapest correct thing to do.

    The name is Claude Code's own `ai-title`, which it rewrites as a session finds its subject,
    so we take the last one in the range and let a later delivery correct it. Reading only the
    delta is deliberate: a transcript can be hundreds of megabytes and re-scanning it every
    turn to find a title we already sent would cost far more than the title is worth.
    """
    turns: list[dict] = []
    title: str | None = None
    title_chosen = False
    consumed = start_offset
    try:
        with open(path, "rb") as handle:
            handle.seek(start_offset)
            data = handle.read()
    except OSError:
        return [], start_offset, None, False

    for raw in data.splitlines(keepends=True):
        if not raw.endswith(b"\n"):
            # The last line is still being written. Leave it for the next delivery - half a
            # JSON object is not a turn, and re-reading it costs nothing.
            break
        line_length = len(raw)
        if not raw.strip():
            consumed += line_length
            continue
        consumed += line_length
        try:
            record = json.loads(raw.decode("utf-8", "replace"))
        except Exception:
            # A complete but unparseable line. Skip it and keep going: refusing to advance
            # would stall this session's capture permanently, and silently, on one bad line.
            continue

        # `/rename` writes `custom-title`; Claude's own naming writes `ai-title`. They are not
        # interchangeable - one is a person's decision and must not be undone by the other on
        # the next turn - so which kind it was travels with the name.
        if record.get("type") == "custom-title":
            named = str(record.get("customTitle") or "").strip()
            if named:
                title, title_chosen = named[:200], True
            continue

        if record.get("type") == "ai-title":
            named = str(record.get("aiTitle") or "").strip()
            if named and not title_chosen:
                title = named[:200]
            continue

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
                # Where this turn ends in the file. The watermark may only ever move to a
                # point that was actually confirmed, so each turn carries its own.
                "_offset": consumed,
            }
        )

    # Older transcripts predate `ai-title` entirely. Rather than leave those permanently
    # "Untitled", name them from the opening question - which is what a person would have
    # called it anyway. Only from the top of a file: mid-conversation there is no opening.
    if title is None and start_offset == 0:
        for turn in turns:
            if turn["role"] == "user":
                first_line = turn["content"].strip().splitlines()[0].strip()
                if first_line:
                    title = first_line[:120]
                break

    return turns, consumed, title, title_chosen


def batches(turns: list[dict], first_seq: int):
    """Number the turns and split them so no single delivery approaches the size ceiling.

    Yields (messages, offset_after_this_batch) so the caller can advance the watermark to
    exactly what was confirmed, and not one byte further.
    """
    batch: list[dict] = []
    size = 0
    seq = first_seq
    end = 0
    for turn in turns:
        numbered = {k: v for k, v in turn.items() if k != "_offset"}
        numbered["seq"] = seq
        seq += 1
        encoded = len(json.dumps(numbered))
        if batch and size + encoded > MAX_DELIVERY_BYTES:
            yield batch, end
            batch, size = [], 0
        batch.append(numbered)
        size += encoded
        end = turn["_offset"]
    if batch:
        yield batch, end


# ------------------------------------------------------------------------------- delivery


def deliver(session_id: str, messages: list[dict], creds: dict, title: str | None = None,
            title_chosen: bool = False) -> bool:
    """POST one delta. True only on a confirmed 2xx - that is what moves the watermark."""
    payload = {"session_id": session_id, "messages": messages}
    if title:
        payload["title"] = title
        # A name somebody typed with /rename must not be undone by the automatic one on the
        # next turn, so the server is told which kind this is.
        if title_chosen:
            payload["title_chosen"] = True
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
                "-X", "POST", f"{creds['api_base']}/functions/v1/capture",
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


def advance_watermark(session_id: str, offset: int, next_seq: int) -> None:
    """Move the mark forward, never backward, under a lock.

    Two hooks can be in flight at once - a slow delivery and the next turn's fast one. Without
    this, the slow one finishes last and writes its older, smaller offset, and the next run
    re-reads turns that were already delivered and re-sends them under sequence numbers that
    now belong to different content. That is worse than a duplicate: it overwrites history.
    """
    import fcntl

    path = watermark_path()
    os.makedirs(os.path.dirname(path), mode=0o700, exist_ok=True)
    lock_path = f"{path}.lock"
    lock_fd = os.open(lock_path, os.O_WRONLY | os.O_CREAT, 0o600)
    try:
        fcntl.flock(lock_fd, fcntl.LOCK_EX)
        marks = read_json(path, {})
        current = marks.get(session_id) or {"offset": 0, "next_seq": 0}
        if offset <= int(current.get("offset", 0)):
            return  # somebody else already got further; leave their mark alone
        marks[session_id] = {"offset": offset, "next_seq": next_seq}
        write_json_private(path, marks)
    finally:
        fcntl.flock(lock_fd, fcntl.LOCK_UN)
        os.close(lock_fd)


def sweep_stale_files(max_age_seconds: int = 3600) -> None:
    """Remove scratch files a killed worker left behind.

    They hold conversation text, and nothing else ever deletes them - a machine that crashes
    mid-delivery would otherwise accumulate transcripts on disk indefinitely.
    """
    now = time.time()
    try:
        for name in os.listdir(plugin_dir()):
            if not name.startswith((".delivery-", ".event-")):
                continue
            path = os.path.join(plugin_dir(), name)
            try:
                if now - os.path.getmtime(path) > max_age_seconds:
                    os.remove(path)
            except OSError:
                continue
    except OSError:
        return


def capture_session(transcript: str, session_id: str, ignore_enrolment: bool = False) -> None:
    """One session's delta, start to finish. Silent on every failure - it is a hook."""
    creds = credentials()
    if not creds["capture_token"] or not creds["hook_secret"] or not creds["api_base"]:
        return
    if not os.path.isfile(transcript):
        return
    # Enrolment. On a machine set up with a pasted key there is no connect step to stamp it,
    # so the first captured turn stamps it instead - and that session starts from here rather
    # than being swallowed whole. Capturing what was said before anyone enrolled is the thing
    # §2.4 forbids; refusing to capture the session you are sitting in is just broken.
    first_run = not os.path.exists(os.path.join(plugin_dir(), "enrolled_at"))
    cutoff = enrolled_at()
    try:
        if first_run and not ignore_enrolment:
            advance_watermark(session_id, os.path.getsize(transcript), 0)
            return
        if os.path.getmtime(transcript) < cutoff and not ignore_enrolment:
            return  # older than enrolment - never ours to take (§2.4)
    except OSError:
        return

    # Let the turn finish landing on disk. Stop fires as Claude finishes speaking, and the
    # assistant's own record is written around that moment - reading instantly captures the
    # question without the answer, and the answer then waits for the next turn. This runs in
    # the detached child, so the person is already back at their prompt and pays nothing.
    time.sleep(SETTLE_SECONDS)

    sweep_stale_files()

    mark = read_json(watermark_path(), {}).get(session_id) or {"offset": 0, "next_seq": 0}
    turns, _end, title, title_chosen = turns_from(transcript, int(mark.get("offset", 0)))
    if not turns:
        return

    blocked = capture_blocked(session_id)
    if blocked:
        # Advance the watermark over the delta without sending it, so it is gone for good.
        advance_watermark(session_id, _end, int(mark.get("next_seq", 0)))
        return

    seq = int(mark.get("next_seq", 0))
    for batch, batch_end in batches(turns, seq):
        # The name rides along with the first batch only. Sending it with every batch would
        # be the same value written repeatedly for no gain.
        if not deliver(session_id, batch, creds, title, title_chosen):
            # Leave the watermark where the last confirmed batch left it. The next turn
            # re-sends from there, and the server dedups. Nothing is lost, nothing doubles.
            return
        title, title_chosen = None, False  # sent once; a later batch would rewrite the same name
        seq = batch[-1]["seq"] + 1
        # Only as far as THIS batch reached. Advancing to the end of the whole delta here
        # would skip the turns in a batch that has not been sent yet.
        advance_watermark(session_id, batch_end, seq)


def backfill(limit: int) -> int:
    """Capture conversations from BEFORE this machine was enrolled. Opt-in, and bounded.

    This is the one path that reaches backwards into somebody's history, so it is a command a
    person runs deliberately, never a default, never a hook, and never silent. The batch is
    bounded because the machines we measured held 378 old sessions and 1.1 GB - shipping that
    in one go would be a first-run stampede as well as a surprise.
    """
    creds = credentials()
    if not creds["capture_token"]:
        print("This machine is not connected. Run /kollate:connect first.")
        return 1

    cutoff = enrolled_at()
    marks = read_json(watermark_path(), {})
    candidates = []
    for directory, _subdirs, files in os.walk(os.path.expanduser("~/.claude/projects")):
        for name in files:
            if not name.endswith(".jsonl"):
                continue
            path = os.path.join(directory, name)
            session_id = name[:-6]
            try:
                if os.path.getmtime(path) >= cutoff:
                    continue  # not history - the ordinary capture path already has it
                if os.path.getsize(path) <= int((marks.get(session_id) or {}).get("offset", 0)):
                    continue
            except OSError:
                continue
            candidates.append((os.path.getmtime(path), path, session_id))

    candidates.sort(reverse=True)  # most recent history first - the useful end of it
    selected = candidates[:limit]
    if not selected:
        print("No conversations from before this machine was connected.")
        return 0

    print(f"Sending {len(selected)} conversation(s) from before this machine was connected.")
    if len(candidates) > len(selected):
        print(f"{len(candidates) - len(selected)} older one(s) not sent - run again to continue.")

    for _mtime, path, session_id in selected:
        capture_session(path, session_id, ignore_enrolment=True)
    print("Done.")
    return 0


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
    for directory, subdirs, files in os.walk(root):
        # A subagent transcript is machinery inside somebody's session, not a conversation they
        # had - capturing it mints a phantom conversation whose first line is an agent prompt.
        # Nothing hooks SubagentStop either, so this scan was the only way they ever got in.
        subdirs[:] = [d for d in subdirs if d != "subagents"]
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


def read_event(timeout_seconds: float = 0.5) -> dict:
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
        # Say out loud that capture is on, once per session - not on compaction, which would
        # repeat it mid-conversation. People should not have to discover monitoring.
        if event.get("source") != "compact":
            creds = credentials()
            if creds["capture_token"] and creds["endpoint"]:
                blocked = capture_blocked(live)
                if blocked:
                    text = (f"Kollate: {blocked} - this conversation is NOT being captured. "
                            "/kollate:resume turns capture back on.")
                else:
                    text = (f"This conversation is captured to Kollate - {creds['endpoint']}/app/conversations . "
                            "Keep this session out: /kollate:pause session · pause everything: "
                            "/kollate:pause 3h|today|week · /kollate:stop")
                print(json.dumps({"systemMessage": text, "suppressOutput": True}))
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

    if command == "backfill":
        # Deliberately not a hook and not a flag anyone can set once and forget: capturing
        # history that predates consent is exactly what the enrolment gate exists to prevent,
        # so it only ever happens when a person runs this command on purpose (§2.4).
        limit = BACKFILL_DEFAULT_LIMIT
        for argument in sys.argv[2:]:
            if argument.startswith("--limit="):
                try:
                    limit = max(1, min(int(argument.split("=", 1)[1]), BACKFILL_MAX_LIMIT))
                except ValueError:
                    pass
        return backfill(limit)

    if command == "pause":
        return cmd_pause(" ".join(sys.argv[2:]).strip().lower())

    if command == "resume":
        return cmd_resume()

    if command == "connect":
        return connect()

    return 0


# ---------------------------------------------------------------------------- the connect


# The last thing a person sees when connecting a machine, so it is worth not looking like a
# stack trace. Colours are the app's own tokens (styles.css `:root` - dark ink, acid lime),
# written literally because this page must render with no network: it is served by a loopback
# socket on a laptop that may well be offline.
_DONE_PAGE = """<!doctype html>
<html lang="en"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>__TITLE__ - Kollate</title>
<style>
  :root {
    --bg: #14181f; --bg: oklch(0.16 0.015 260);
    --card: #1b2029; --card: oklch(0.20 0.018 260);
    --fg: #f5f6f8; --fg: oklch(0.97 0.005 260);
    --muted: #a3a9b5; --muted: oklch(0.70 0.02 260);
    --border: #363b45; --border: oklch(0.28 0.015 260);
    --lime: #c3f53c; --lime: oklch(0.90 0.22 130);
  }
  * { box-sizing: border-box; }
  body {
    margin: 0; min-height: 100vh; display: grid; place-items: center; padding: 1.5rem;
    background: var(--bg); color: var(--fg);
    font: 15px/1.6 system-ui, -apple-system, "Segoe UI", sans-serif;
  }
  .card {
    width: 100%; max-width: 26rem; padding: 2rem;
    background: var(--card); border: 1px solid var(--border); border-radius: 0.625rem;
  }
  .brand {
    display: flex; align-items: center; gap: 0.5rem;
    font-size: 1.0625rem; font-weight: 600; letter-spacing: -0.01em;
  }
  .mark { width: 0.75rem; height: 0.75rem; border-radius: 0.1875rem; background: var(--lime); }
  h1 { margin: 1.75rem 0 0; font-size: 1.375rem; font-weight: 600; letter-spacing: -0.015em; }
  p { margin: 0.5rem 0 0; color: var(--muted); }
  ul { margin: 1.25rem 0 0; padding: 0; list-style: none; }
  li { position: relative; padding-inline-start: 1.25rem; margin-top: 0.5rem; color: var(--muted); }
  li::before {
    content: ""; position: absolute; inset-inline-start: 0; top: 0.6875rem;
    width: 0.375rem; height: 0.375rem; border-radius: 999px; background: var(--lime);
  }
  a.go {
    display: inline-block; margin-top: 1.75rem; padding: 0.5rem 1rem;
    background: var(--lime); color: var(--bg); text-decoration: none;
    font-weight: 500; border-radius: 0.5rem;
  }
  .close { margin-top: 1rem; font-size: 0.8125rem; }
</style></head>
<body><main class="card">
  <div class="brand"><span class="mark"></span>Kollate</div>
  <h1>__HEADING__</h1>
  <p>__BODY__</p>
  __EXTRA__
</main></body></html>
"""

_CONNECTED_EXTRA = """<ul>
    <li>New conversations on this machine are saved to your workspace as they happen.</li>
    <li>Anything from before now is left alone - connecting does not reach backwards.</li>
    <li>Your workspace admins can read what is captured.</li>
    <li>Disconnect this machine any time from Connect in Kollate.</li>
  </ul>
  __BUTTON__
  <p class="close">You can close this tab - Claude Code is finishing up.</p>"""

_FAILED_EXTRA = """<p class="close">Close this tab and run /kollate:connect again.</p>"""


def done_page(ok: bool, endpoint: str = "") -> str:
    """The loopback listener's only response. `ok` is false when nothing usable came back."""
    if ok:
        title, heading = "Connected", "This machine is connected."
        body = "Go back to your workspace - from here on, your Claude Code conversations are preserved in Kollate."
        button = ""
        # Only offer the link if the address is one we would trust anywhere else.
        if safe_api_base(endpoint):
            target = html.escape(endpoint.rstrip("/") + "/app/conversations", quote=True)
            button = f'<a class="go" href="{target}">Open your workspace</a>'
        extra = _CONNECTED_EXTRA.replace("__BUTTON__", button)
    else:
        title, heading = "Not connected", "That did not complete."
        body = "Nothing was changed, and this machine is not connected."
        extra = _FAILED_EXTRA

    return (
        _DONE_PAGE.replace("__TITLE__", title)
        .replace("__HEADING__", heading)
        .replace("__BODY__", body)
        .replace("__EXTRA__", extra)
    )


def connect() -> int:
    """Loopback sign-in. The person sees their normal Kollate login and nothing else."""
    import http.server
    import socket
    import threading
    import webbrowser

    endpoint = configured_endpoint()
    if not endpoint:
        print(
            "Set your Kollate address first: run /plugin, configure the kollate plugin, and\n"
            "put your organisation's Kollate URL in 'Kollate URL'."
        )
        return 1

    # Check the address answers before opening a browser at it. A URL that resolves to
    # nothing would otherwise look like a sign-in that simply never completed.
    try:
        probe = subprocess.run(
            ["curl", "-s", "-o", "/dev/null", "-w", "%{http_code}", "--max-time", "10", endpoint],
            capture_output=True, text=True, timeout=20,
        )
        if not (probe.stdout or "").strip().startswith(("2", "3", "4")):
            print(f"{endpoint} did not respond. Check the address and try again.")
            return 1
    except Exception:
        print(f"{endpoint} could not be reached. Check the address and try again.")
        return 1

    probe = socket.socket()
    probe.bind(("127.0.0.1", 0))
    port = probe.getsockname()[1]
    probe.close()

    redirect_uri = f"http://127.0.0.1:{port}/callback"
    state = hashlib.sha256(os.urandom(32)).hexdigest()[:32]
    received: dict[str, str] = {}

    label = f"{os.uname().nodename}"
    # Filled in by the handler thread, read by this one once it is done.
    outcome: dict[str, object] = {}

    def finish(received: dict[str, str]) -> tuple[bool, str]:
        """Redeem the code and store the credential. Runs before the browser is answered."""
        # Kollate refuses some connects for reasons only it knows - no workspace yet, most
        # commonly. It says so on the redirect, so pass that on rather than making the person
        # watch a silent terminal for three minutes and guess.
        refused = printable(received.get("error") or "")
        if refused and received.get("state") == state:
            return False, refused + " Nothing was changed."

        if received.get("state") != state or not received.get("code"):
            return False, "Sign-in did not complete. Nothing was changed."

        api_base = safe_api_base(received.get("api") or "")
        if not api_base:
            return False, "Kollate did not say where to deliver to. Update Kollate and try again."

        # If this machine has connected before, name that connection so it is rotated rather
        # than duplicated - one laptop should be one row on the person's Connect page.
        request = {"code": received["code"], "redirect_uri": redirect_uri, "label": label}
        previous = (read_json(credentials_path(), {}).get("connection_id")
                    or read_json(os.path.join(shared_dir(), "credentials.json"), {}).get("connection_id"))
        if previous:
            request["connection_id"] = previous

        try:
            result = subprocess.run(
                [
                    "curl", "-s", "--max-time", "20",
                    "-X", "POST", f"{api_base}/functions/v1/connect-exchange",
                    "-H", "Content-Type: application/json",
                    "--data-binary", "@-",
                ],
                input=json.dumps(request),
                capture_output=True,
                text=True,
                timeout=30,
            )
            issued = json.loads(result.stdout or "{}")
        except Exception:
            issued = {}

        if not issued.get("capture_token") or not issued.get("hook_secret"):
            return False, "Could not complete the connection. Nothing was changed."

        # Replace any previous credential in place, so connecting twice does not leave two
        # machines behind. Owner-only, and it lives in CLAUDE_PLUGIN_DATA so a plugin update
        # does not take it with it.
        #
        # Written to the shared location as well, because the terminal and the desktop app do
        # not agree on CLAUDE_PLUGIN_DATA. Connecting from one should not leave the other
        # silently uncaptured on the same machine, by the same person.
        credential = {
            "capture_token": issued["capture_token"],
            "hook_secret": issued["hook_secret"],
            "connection_id": issued.get("connection_id"),
            "endpoint": endpoint,
            "api_base": api_base,
        }
        for target in {credentials_path(), os.path.join(shared_dir(), "credentials.json")}:
            write_json_private(target, credential)
        enrolled_at()
        return True, "Connected. New Claude Code conversations on this machine will be saved to Kollate."

    class Handler(http.server.BaseHTTPRequestHandler):
        def do_GET(self):  # noqa: N802 - stdlib naming
            parsed = urllib.parse.urlparse(self.path)
            # Browsers ask for /favicon.ico on any new origin, unbidden. Answering that as
            # though it were the callback would consume our one request and lose the real
            # one, so anything but the callback is turned away and we keep listening.
            if parsed.path != "/callback":
                self.send_response(404)
                self.end_headers()
                return

            received = {k: v[0] for k, v in urllib.parse.parse_qs(parsed.query).items()}
            # Redeem BEFORE answering. The page is the only thing most people read, so it
            # must not say "connected" while the exchange is still ahead of it and able to
            # fail - the terminal they were told to walk away from would be the only place
            # that ever said otherwise.
            try:
                ok, message = finish(received)
            except Exception:
                ok, message = False, "Could not complete the connection. Nothing was changed."
            outcome["ok"], outcome["message"] = ok, message

            body = done_page(ok, endpoint).encode("utf-8")
            self.send_response(200)
            self.send_header("Content-Type", "text/html; charset=utf-8")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)

        def log_message(self, *args):  # keep the terminal clean
            pass

    server = http.server.HTTPServer(("127.0.0.1", port), Handler)
    server.timeout = 30

    def serve_until_answered() -> None:
        deadline = time.time() + 180
        while "ok" not in outcome and time.time() < deadline:
            server.handle_request()  # returns on timeout too, which re-checks the deadline

    thread = threading.Thread(target=serve_until_answered, daemon=True)
    thread.start()

    url = (
        f"{endpoint}/connect-machine?redirect_uri={urllib.parse.quote(redirect_uri, safe='')}"
        f"&state={state}&label={urllib.parse.quote(label, safe='')}"
    )
    print("Opening your browser to sign in to Kollate...")
    if not webbrowser.open(url):
        print(f"Open this link to finish connecting:\n  {url}")

    thread.join(timeout=185)
    print(outcome.get("message") or "Sign-in did not complete. Nothing was changed.")
    return 0 if outcome.get("ok") else 1


if __name__ == "__main__":
    sys.exit(main())
