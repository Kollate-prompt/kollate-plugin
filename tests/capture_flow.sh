#!/usr/bin/env bash
# Drives the plugin the way Claude Code drives it: a Stop event on stdin, a real transcript
# on disk, a real endpoint. Nothing here mocks the delivery path.
#
# Needs the app's dev server and the local Supabase stack, with the connection seeded by
# app/supabase/tests/seed_capture_connection.sql.
#
#   bash plugin/tests/capture_flow.sh
set -uo pipefail

BASE="${BASE:-http://127.0.0.1:54321}"   # Supabase, where the edge functions live
DB="${DB:-postgresql://postgres:postgres@127.0.0.1:54322/postgres}"
TOKEN="${TOKEN:-test-capture-token-abc123}"
SECRET="${SECRET:-test-hook-secret}"

HOOKS="$(cd "$(dirname "$0")/../plugins/kollate/hooks" && pwd)"
WORK=$(mktemp -d)
export CLAUDE_PLUGIN_DATA="$WORK/data"
SESSION="plugin-check-$$"
TRANSCRIPT="$WORK/$SESSION.jsonl"

pass=0; fail=0
check() { if [ "$2" = "$3" ]; then printf '  ok   %-46s %s\n' "$1" "$3"; pass=$((pass+1));
          else printf '  FAIL %-46s expected %s, got %s\n' "$1" "$2" "$3"; fail=$((fail+1)); fi }

mkdir -p "$CLAUDE_PLUGIN_DATA"
chmod 700 "$CLAUDE_PLUGIN_DATA"
cat > "$CLAUDE_PLUGIN_DATA/credentials.json" <<JSON
{"capture_token":"$TOKEN","hook_secret":"$SECRET","endpoint":"$BASE","api_base":"$BASE"}
JSON
chmod 600 "$CLAUDE_PLUGIN_DATA/credentials.json"
# Enrolment is stamped at connect time, before any conversation exists. Reproduce that
# order here - otherwise the fixture transcript looks fractionally older than enrolment and
# is correctly ignored.
python3 -c "import time;open('$CLAUDE_PLUGIN_DATA/enrolled_at','w').write(str(time.time()-5))"
chmod 600 "$CLAUDE_PLUGIN_DATA/enrolled_at"

turn() { # role text uuid -> one transcript line
  python3 -c "
import json,sys
print(json.dumps({'type':sys.argv[1],'uuid':sys.argv[3],'timestamp':'2026-08-13T12:00:00.000Z',
                  'sessionId':'$SESSION','message':{'role':sys.argv[1],'content':[{'type':'text','text':sys.argv[2]}]}}))" "$1" "$2" "$3"
}

fire() { # run the Stop hook exactly as Claude Code would, and wait for its detached child
  printf '{"session_id":"%s","transcript_path":"%s"}' "$SESSION" "$TRANSCRIPT" \
    | python3 "$HOOKS/kollate.py" capture
  sleep 3
}

stored() {
  psql "$DB" -At -c "select coalesce(string_agg(m.role || ':' || m.content, '|' order by m.seq),'')
    from public.messages m join public.conversations c on c.id = m.conversation_id
    where c.session_id = '$SESSION'"
}

echo "plugin capture checks against $BASE"

# A first turn, plus the noise a real transcript carries.
{
  turn user "first question" u1
  turn assistant "first answer" u2
  echo '{"type":"system","uuid":"n1","content":"noise"}'
  python3 -c "
import json
print(json.dumps({'type':'assistant','uuid':'t1','sessionId':'$SESSION','message':{'role':'assistant','content':[
  {'type':'thinking','thinking':'SECRET REASONING'},
  {'type':'tool_use','name':'Bash','id':'x','input':{'command':'ls'}}]}}))"
} > "$TRANSCRIPT"

fire
check "first turn delivered"        "user:first question|assistant:first answer" "$(stored)"

# Thinking is not a stored message, and it must not be anywhere in the conversation.
leak=$(psql "$DB" -At -c "select count(*) from public.messages m
  join public.conversations c on c.id = m.conversation_id
  where c.session_id = '$SESSION' and m.content like '%SECRET REASONING%'")
check "thinking never stored"       0 "$leak"

# The next turn is a delta: only what is new goes, and seq continues where it left off.
turn user "second question" u3 >> "$TRANSCRIPT"
turn assistant "second answer" u4 >> "$TRANSCRIPT"
fire
check "delta appended in order" \
  "user:first question|assistant:first answer|user:second question|assistant:second answer" "$(stored)"

seqs=$(psql "$DB" -At -c "select string_agg(m.seq::text, ',' order by m.seq)
  from public.messages m join public.conversations c on c.id = m.conversation_id
  where c.session_id = '$SESSION'")
check "seq is continuous"           "0,1,2,3" "$seqs"

# Firing again with nothing new must be a no-op, not a re-send.
fire
count=$(psql "$DB" -At -c "select count(*) from public.messages m
  join public.conversations c on c.id = m.conversation_id where c.session_id = '$SESSION'")
check "nothing new, nothing sent"   4 "$count"

conversations=$(psql "$DB" -At -c "select count(*) from public.conversations where session_id = '$SESSION'")
check "one conversation throughout" 1 "$conversations"

# Naming. Claude Code writes its own `ai-title` into the transcript; capture carries it so a
# list of conversations is readable instead of a wall of "Untitled".
title_of() { psql "$DB" -At -c "select coalesce(title,'') from public.conversations where session_id = '$SESSION'"; }

echo '{"type":"ai-title","aiTitle":"Naming the conversation","sessionId":"'"$SESSION"'"}' >> "$TRANSCRIPT"
turn user "third question" t1 >> "$TRANSCRIPT"
fire
check "conversation takes its name"  "Naming the conversation" "$(title_of)"

# The name follows the session as its subject changes - until somebody chooses one.
echo '{"type":"ai-title","aiTitle":"A better name","sessionId":"'"$SESSION"'"}' >> "$TRANSCRIPT"
turn user "fourth question" t2 >> "$TRANSCRIPT"
fire
check "capture may improve the name" "A better name" "$(title_of)"

# A name a person chose must never be overwritten by the next turn - that is the whole point
# of being able to rename, and the easiest thing to get wrong.
psql "$DB" -q -c "update public.conversations set title = 'Chosen by hand', renamed_at = now()
                  where session_id = '$SESSION'"
echo '{"type":"ai-title","aiTitle":"Capture tries again","sessionId":"'"$SESSION"'"}' >> "$TRANSCRIPT"
turn user "fifth question" t3 >> "$TRANSCRIPT"
fire
check "a chosen name is never overwritten" "Chosen by hand" "$(title_of)"

# --- the endpoint is down -------------------------------------------------------------
# The watermark must not move, so the next successful turn re-delivers what was missed.
python3 -c "
import json
p='$CLAUDE_PLUGIN_DATA/credentials.json'
d=json.load(open(p)); d['api_base']='http://127.0.0.1:9'; json.dump(d, open(p,'w'))"
turn user "sent while the server was down" u5 >> "$TRANSCRIPT"
fire
missing=$(psql "$DB" -At -c "select count(*) from public.messages m
  join public.conversations c on c.id = m.conversation_id
  where c.session_id = '$SESSION' and m.content like '%server was down%'")
check "nothing stored while down"   0 "$missing"

python3 -c "
import json
p='$CLAUDE_PLUGIN_DATA/credentials.json'
d=json.load(open(p)); d['api_base']='$BASE'; json.dump(d, open(p,'w'))"
fire
recovered=$(psql "$DB" -At -c "select count(*) from public.messages m
  join public.conversations c on c.id = m.conversation_id
  where c.session_id = '$SESSION' and m.content like '%server was down%'")
check "recovered on the next turn"  1 "$recovered"

total=$(psql "$DB" -At -c "select count(*) from public.messages m
  join public.conversations c on c.id = m.conversation_id where c.session_id = '$SESSION'")
# 4 from the opening exchanges, 3 more from the naming checks, 1 recovered here.
check "no duplicates after recovery" 8 "$total"

# --- the session is never slowed -------------------------------------------------------
# Work order §02.4: measured across every round, not sampled once at exit. Timed around the
# hook process itself - the same way Claude Code invokes it - rather than around a shell
# pipeline, whose own fork and printf would be counted as if the plugin had spent them.
latency=$(python3 - <<PY
import json, subprocess, time
event = json.dumps({"session_id": "$SESSION", "transcript_path": "$TRANSCRIPT"})
rounds = []
for _ in range(12):
    started = time.perf_counter()
    subprocess.run(["python3", "-S", "-E", "$HOOKS/kollate.py", "capture"],
                   input=event, text=True, capture_output=True)
    rounds.append((time.perf_counter() - started) * 1000)
rounds.sort()
print("%d %d" % (rounds[len(rounds) // 2], rounds[-1]))
PY
)
median=${latency% *}; worst=${latency#* }
# The plugin's own work is a few milliseconds; the rest is Python starting up, which every
# hook on the machine pays and which stretches when the machine is busy. Hold the typical
# round to the 50ms budget, and keep a ceiling on the worst so a real regression still shows.
if [ "$median" -lt 50 ] && [ "$worst" -lt 150 ]; then
  printf '  ok   %-46s median %sms, worst %sms\n' "hook returns in under 50ms" "$median" "$worst"; pass=$((pass+1))
else
  printf '  FAIL %-46s median %sms, worst %sms\n' "hook returns in under 50ms" "$median" "$worst"; fail=$((fail+1))
fi

# --- things an adversarial pass found, kept as regressions -------------------------------

# A transcript that predates enrolment is never captured, however full it is.
OLD_SESSION="plugin-old-$$"
OLD_TRANSCRIPT="$WORK/$OLD_SESSION.jsonl"
turn user "FROM BEFORE ENROLMENT" old1 > "$OLD_TRANSCRIPT"
touch -t 202001010000 "$OLD_TRANSCRIPT"
printf '{"session_id":"%s","transcript_path":"%s"}' "$OLD_SESSION" "$OLD_TRANSCRIPT" \
  | python3 -S -E "$HOOKS/kollate.py" capture
sleep 2
pre=$(psql "$DB" -At -c "select count(*) from public.messages m
  join public.conversations c on c.id = m.conversation_id
  where c.session_id = '$OLD_SESSION'")
check "pre-enrolment history untouched" 0 "$pre"

# One corrupt line must not stall the session forever - everything after it still arrives.
BAD_SESSION="plugin-bad-$$"
BAD_TRANSCRIPT="$WORK/$BAD_SESSION.jsonl"
{ turn user "before the bad line" b1
  echo '{this is not valid json,,,'
  turn user "after the bad line" b2
} > "$BAD_TRANSCRIPT"
printf '{"session_id":"%s","transcript_path":"%s"}' "$BAD_SESSION" "$BAD_TRANSCRIPT" \
  | python3 -S -E "$HOOKS/kollate.py" capture
sleep 3
after=$(psql "$DB" -At -c "select count(*) from public.messages m
  join public.conversations c on c.id = m.conversation_id
  where c.session_id = '$BAD_SESSION' and m.content = 'after the bad line'")
check "corrupt line does not stall capture" 1 "$after"

# A stale worker must never drag the watermark backwards, which would re-use seq numbers
# for different content and overwrite delivered history.
python3 - <<PY
import json, os, subprocess, sys
sys.path.insert(0, "$HOOKS")
os.environ["CLAUDE_PLUGIN_DATA"] = "$CLAUDE_PLUGIN_DATA"
import kollate
kollate.advance_watermark("race-check", 500, 9)
kollate.advance_watermark("race-check", 100, 2)   # a slow worker finishing late
mark = kollate.read_json(kollate.watermark_path(), {})["race-check"]
print(json.dumps(mark))
PY
mark=$(python3 -c "
import json;print(json.load(open('$CLAUDE_PLUGIN_DATA/delivered.json'))['race-check']['offset'])")
check "watermark never moves backwards" 500 "$mark"

psql "$DB" -q -c "delete from public.conversations where session_id in ('$OLD_SESSION','$BAD_SESSION')"

# --- the no-browser path ----------------------------------------------------------------
# A machine over SSH pastes one setup key instead of signing in. It must capture identically.
PASTED=$(python3 -c "
import base64, json
print('kollate_' + base64.urlsafe_b64encode(json.dumps(
  {'t':'$TOKEN','s':'$SECRET','c':'dddddddd-dddd-dddd-dddd-dddddddddddd','a':'$BASE'}).encode()).decode().rstrip('='))")
FALLBACK_DATA="$WORK/nobrowser"
mkdir -p "$FALLBACK_DATA"
SESSION2="plugin-nobrowser-$$"
TRANSCRIPT2="$WORK/$SESSION2.jsonl"
python3 -c "
import json
print(json.dumps({'type':'user','uuid':'nb1','timestamp':'2026-08-13T12:00:00.000Z',
                  'message':{'role':'user','content':[{'type':'text','text':'pasted key works'}]}}))" > "$TRANSCRIPT2"

fallback_fire() {
  printf '{"session_id":"%s","transcript_path":"%s"}' "$SESSION2" "$TRANSCRIPT2" | \
    env CLAUDE_PLUGIN_DATA="$FALLBACK_DATA" \
        CLAUDE_PLUGIN_OPTION_CAPTURE_TOKEN="$PASTED" \
        CLAUDE_PLUGIN_OPTION_ENDPOINT="$BASE" \
        python3 -S -E "$HOOKS/kollate.py" capture
  sleep 3
}

# There is no connect step on this path, so the first captured turn is what stamps enrolment.
# What was already in the transcript at that moment is history, and history is not taken.
fallback_fire
history=$(psql "$DB" -At -c "select count(*) from public.messages m
  join public.conversations c on c.id = m.conversation_id
  where c.session_id = '$SESSION2' and m.content = 'pasted key works'")
check "pasted key takes no history"  0 "$history"

# From the next turn on, it captures exactly like the browser path.
python3 -c "
import json
print(json.dumps({'type':'user','uuid':'nb2','timestamp':'2026-08-13T12:01:00.000Z',
                  'message':{'role':'user','content':[{'type':'text','text':'after the pasted key'}]}}))" >> "$TRANSCRIPT2"
fallback_fire
pasted_stored=$(psql "$DB" -At -c "select count(*) from public.messages m
  join public.conversations c on c.id = m.conversation_id
  where c.session_id = '$SESSION2' and m.content = 'after the pasted key'")
check "pasted setup key captures"   1 "$pasted_stored"

keysize=${#PASTED}
if [ "$keysize" -lt 2048 ]; then
  printf '  ok   %-46s %s chars\n' "setup key fits the keychain budget" "$keysize"; pass=$((pass+1))
else
  printf '  FAIL %-46s %s chars\n' "setup key fits the keychain budget" "$keysize"; fail=$((fail+1))
fi

sensitive=$(python3 -c "
import json
m=json.load(open('$(dirname "$0")/../plugins/kollate/.claude-plugin/plugin.json'))
print(m['userConfig']['capture_token'].get('sensitive') is True)")
check "setup key is declared sensitive" True "$sensitive"

psql "$DB" -q -c "delete from public.conversations where session_id = '$SESSION2'"

# --- crash recovery, and backfill being off by default ----------------------------------
# A crash means no Stop hook ever ran, so nothing was spooled. Recovery is the watermark scan
# at session start, and it must pick up what the crash left behind.
CRASH_HOME="$WORK/crash"
mkdir -p "$CRASH_HOME/projects/proj"
cp "$CLAUDE_PLUGIN_DATA/credentials.json" "$WORK/crashcreds.json"
CRASH_SESSION="plugin-crash-$$"
CRASH_TRANSCRIPT="$CRASH_HOME/projects/proj/$CRASH_SESSION.jsonl"
turn user "survived the crash" c1 > "$CRASH_TRANSCRIPT"

# reconcile scans ~/.claude/projects, so point HOME at a fixture tree containing one
# undelivered transcript, exactly as a machine that died mid-session would have.
mkdir -p "$CRASH_HOME/.claude"
mv "$CRASH_HOME/projects" "$CRASH_HOME/.claude/projects"
CRASH_TRANSCRIPT="$CRASH_HOME/.claude/projects/proj/$CRASH_SESSION.jsonl"
env HOME="$CRASH_HOME" CLAUDE_PLUGIN_DATA="$CLAUDE_PLUGIN_DATA" \
    python3 -S -E "$HOOKS/kollate.py" reconcile <<< '{"session_id":"some-other-live-session"}'
sleep 3
recovered_crash=$(psql "$DB" -At -c "select count(*) from public.messages m
  join public.conversations c on c.id = m.conversation_id
  where c.session_id = '$CRASH_SESSION' and m.content = 'survived the crash'")
check "crash recovered at session start" 1 "$recovered_crash"

# Backfill must never be something a hook does. Nothing in hooks.json may invoke it.
hooked=$(grep -c "backfill" "$HOOKS/hooks.json" || true)
check "backfill is not wired to any hook" 0 "$hooked"

# And when run deliberately, it is bounded.
BF_HOME="$WORK/backfill"
mkdir -p "$BF_HOME/.claude/projects/proj"
for i in 1 2 3; do
  turn user "old conversation $i" "bf$i" > "$BF_HOME/.claude/projects/proj/plugin-bf$i-$$.jsonl"
  touch -t 202001010000 "$BF_HOME/.claude/projects/proj/plugin-bf$i-$$.jsonl"
done
env HOME="$BF_HOME" CLAUDE_PLUGIN_DATA="$CLAUDE_PLUGIN_DATA" \
    python3 -S -E "$HOOKS/kollate.py" backfill --limit=2 > "$WORK/backfill.out" 2>&1
sleep 3
sent=$(psql "$DB" -At -c "select count(*) from public.conversations where session_id like 'plugin-bf%'")
check "backfill sends only its limit"    2 "$sent"
grep -q "not sent" "$WORK/backfill.out" \
  && { printf '  ok   %-46s %s\n' "backfill says what it left behind" "reported"; pass=$((pass+1)); } \
  || { printf '  FAIL %-46s %s\n' "backfill says what it left behind" "silent"; fail=$((fail+1)); }

psql "$DB" -q -c "delete from public.conversations where session_id like 'plugin-bf%' or session_id = '$CRASH_SESSION'"

# --- the delivery address is not something anyone can steer ------------------------------
# It decides where a bearer token and conversation text get posted, and it arrives from
# outside: a callback parameter, or a setup key somebody was handed.
addr=$(python3 -c "
import sys; sys.path.insert(0, '$HOOKS')
import kollate
bad = ['http://evil.example.com', 'https://user:pw@evil.example.com',
       'https://evil.example.com?x=1', 'file:///etc/passwd', 'javascript:alert(1)']
good = ['https://xqtblcyqojtnvsvfqrmp.supabase.co', 'http://127.0.0.1:54321']
print('ok' if all(not kollate.safe_api_base(b) for b in bad)
              and all(kollate.safe_api_base(g) for g in good) else 'leaky')")
check "untrusted delivery addresses refused" ok "$addr"

# A setup key naming somewhere else must not produce a working machine.
HOSTILE=$(python3 -c "
import base64, json
print('kollate_' + base64.urlsafe_b64encode(json.dumps(
  {'t':'$TOKEN','s':'$SECRET','c':'dddddddd-dddd-dddd-dddd-dddddddddddd',
   'a':'http://evil.example.com'}).encode()).decode().rstrip('='))")
HOSTILE_DATA="$WORK/hostile"; mkdir -p "$HOSTILE_DATA"
printf '{"session_id":"%s","transcript_path":"%s"}' "hostile-$$" "$TRANSCRIPT" | \
  env CLAUDE_PLUGIN_DATA="$HOSTILE_DATA" CLAUDE_PLUGIN_OPTION_CAPTURE_TOKEN="$HOSTILE" \
      python3 -S -E "$HOOKS/kollate.py" capture
sleep 2
leaked=$(psql "$DB" -At -c "select count(*) from public.conversations where session_id = 'hostile-$$'")
check "hostile setup key delivers nothing" 0 "$leaked"

# --- credentials on disk ---------------------------------------------------------------
mode=$(stat -f '%Lp' "$CLAUDE_PLUGIN_DATA/credentials.json" 2>/dev/null || stat -c '%a' "$CLAUDE_PLUGIN_DATA/credentials.json")
check "credentials are owner-only"  600 "$mode"
dirmode=$(stat -f '%Lp' "$CLAUDE_PLUGIN_DATA" 2>/dev/null || stat -c '%a' "$CLAUDE_PLUGIN_DATA")
check "plugin data dir is owner-only" 700 "$dirmode"

# Nothing the plugin leaves behind may contain a transcript.
sleep 2
residue=$(grep -rl "first question" "$CLAUDE_PLUGIN_DATA" 2>/dev/null | wc -l | tr -d ' ')
check "no conversation left on disk" 0 "$residue"

# The token must never reach argv, where `ps` would expose it to every user on the machine.
argv_leak=$(grep -c -- "-H.*Bearer" "$HOOKS/kollate.py")
check "no bearer token in argv"     0 "$argv_leak"

psql "$DB" -q -c "delete from public.conversations where session_id = '$SESSION'"
rm -rf "$WORK"

echo
echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
