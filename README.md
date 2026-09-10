# Kollate for Claude Code

Captures your Claude Code conversations into your organisation's Kollate workspace, so the
work your team does with Claude stops evaporating when a session ends.

## Install

One command. Put your own Kollate address at the end — it is the address you sign in at, and it
is shown on the Connect page inside Kollate.

```bash
curl -fsSL https://raw.githubusercontent.com/Kollate-prompt/kollate-plugin/main/install.sh | bash -s -- https://your-kollate-address
```

Then **quit Claude Code completely and open it again** — plugins load at startup, so a session
that is already running will not see this one. Finally, inside Claude Code:

```
/kollate:connect
```

Your browser opens the Kollate sign-in you already use. Approve, and this machine is
connected. **You are never shown a key, never paste one, and never edit a file.**

<details>
<summary>Doing it by hand instead</summary>

```bash
claude plugin marketplace add Kollate-prompt/kollate-plugin
claude plugin install kollate
```

Then set **Kollate URL** from `/plugin` → configure `kollate`. (Newer builds accept
`--config endpoint=https://your-kollate-address` on the install line; older ones reject it,
which is why the script writes the setting directly.)

Claude Code will mention that one userConfig option is still unset. That is the setup key, which
only machines with no browser need — ignore it unless you are on one.
</details>

### The Claude desktop app

The same install works. Two things to know:

- **Quit and reopen the app itself** after installing — not the window. Plugins load at startup,
  and until you do, `/kollate:connect` will not appear when you type it.
- **Cloud sessions are not captured.** If the session shows a cloud icon and asks you to pick a
  repository, it is running on Anthropic's infrastructure rather than on your machine, and
  nothing on your machine can see it. Local sessions capture normally.

## What gets captured

From the moment you connect, and never before it:

- your turns and Claude's replies, as text, in order
- nothing else - no thinking blocks, no tool output, no attachments, no file contents

Conversations from before you connected are ignored entirely. Connecting does not reach
backwards through your history.

## Where it goes

To the Kollate workspace you signed in to, attributed to you. Your organisation's admins can
read your captured conversations - that is what "organisational memory" means, and it is
worth knowing rather than discovering.

## Turning it off

Disconnect the machine from **Connect** in Kollate. It stops being accepted immediately, on
its very next turn. Or remove the plugin:

```bash
claude plugin uninstall kollate
```

## Requirements

- Python 3 and `curl`, both of which macOS and Linux already have
- Claude Code

## How it behaves

- **It never slows your session.** The hook hands off and exits in well under 50 ms; delivery
  happens behind you.
- **It never loses a turn.** If Kollate cannot be reached, nothing is marked as delivered, and
  the next turn sends it again. Delivering the same turn twice stores it once.
- **It fails silently.** A capture plugin that interrupts your work to complain about a network
  problem is worse than one that quietly catches up later.

## Where your credential lives

In Claude Code's plugin data directory, readable only by you (`0600`), and it survives plugin
updates. It is never passed as a command-line argument, where any other user on the machine
could read it out of the process list.

## Tests

```bash
./tests/run-all.sh            # everything that needs no database
./tests/run-all.sh out.log    # and keep the log
```

| Suite | What it proves |
|---|---|
| `endpoint_resolution.sh` | The workspace address resolves in the right order, including on a surface with no settings screen |
| `claude_capture.sh` | Claude Code: parsing, delivery, watermark, and the things that must never be captured |
| `codex_capture.sh` | Codex: the same, plus its own record shape, its scaffolding, and the frozen hook command string |
| `live_transcripts.sh` | The real hook over this machine's own newest transcript from each tool |
| `hook_budget.sh` | The hook stays off the keystroke path, and its work survives being cut off |

`capture_flow.sh` is not in that runner: it needs a local Supabase and `psql`, so it cannot be the
thing anybody runs to check a change quickly. Run it separately when the server contract changes.

## Codex

Codex will not run a hook until somebody approves it, and says nothing when it skips one. After
installing, start Codex, run `/hooks`, and trust Kollate's. `kollate:status` says whether the hooks
have ever actually run.

**The hook command string in `hooks-codex.json` must never change.** Codex pins hook trust to a hash
of that exact string: a version bump keeps the trust, an edited command revokes it everywhere at
once, silently. `codex_capture.sh` freezes it for that reason.

**Windows runs the hook without a shell.** On macOS and Linux Codex hands the command to a
shell, so the `A || B || C` interpreter probe falls through to whichever Python exists. On
Windows it does not: the chain is never executed and Codex reports the hook as Failed, so
nothing is captured. `hooks-codex-windows.json` is the same three hooks as one `py -3`
invocation each, and `install.ps1` points the installed copy at it. Rerun the installer after
`codex plugin marketplace upgrade` — an upgrade restores the plugin's own manifest choice.

**Codex sandboxes a skill's command; it does not sandbox a hook.** Capture is unaffected —
hooks run with full access, which is how delivery works at all. The commands are another
matter: Codex's default mode ("Auto") lets a command write only inside the project and gives
it no network, and everything Kollate changes lives in `~/.kollate`. The installer therefore
adds that one directory to `sandbox_workspace_write.writable_roots` in `~/.codex/config.toml`
(merging into whatever is already there, keeping a `.kollate-backup` beside it), which is what
makes `kollate:pause`, `resume`, `stop` and `record` work from inside a session. `connect`,
`update` and `backfill` need the network as well, so under Codex they say so and print the
command to run in a terminal instead. Nothing here ever reports success for a change that did
not reach disk.
