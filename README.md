# Kollate for Claude Code

Captures your Claude Code conversations into your organisation's Kollate workspace, so the
work your team does with Claude stops evaporating when a session ends.

## Install

```bash
claude plugin marketplace add Kollate-prompt/kollate-plugin
claude plugin install kollate
```

Then tell it where your Kollate lives — run `/plugin`, configure the kollate plugin, and set
**Kollate URL** to your organisation's address. The plugin will not guess it: an address that
resolves to nothing looks exactly like capture working, and that is the one failure mode worth
refusing to ship.

Then, in Claude Code:

```
/kollate:connect
```

Your browser opens the Kollate sign-in you already use. Approve, and this machine is
connected. **You are never shown a key, never paste one, and never edit a file.**

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
