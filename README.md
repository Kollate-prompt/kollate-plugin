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

### The Claude desktop app is not supported yet

The desktop app keeps its plugins in its own registry, separate from the one `claude plugin
install` writes to, and its cloud sessions run on Anthropic's infrastructure where nothing on
your machine can observe them. Use Claude Code in a terminal.

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
