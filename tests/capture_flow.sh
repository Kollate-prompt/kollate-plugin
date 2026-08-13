#!/usr/bin/env bash
# Drives the plugin the way Claude Code drives it: a Stop event on stdin, a real transcript
# on disk, a real endpoint. Nothing here mocks the delivery path.
#
# Needs the app's dev server and the local Supabase stack, with the connection seeded by
# app/supabase/tests/seed_capture_connection.sql.
#
#   bash plugin/tests/capture_flow.sh
set -uo pipefail

BASE="${BASE:-http://localhost:8080}"
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
{"capture_token":"$TOKEN","hook_secret":"$SECRET","endpoint":"$BASE"}
JSON
chmod 600 "$CLAUDE_PLUGIN_DATA/credentials.json"

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

# --- the endpoint is down -------------------------------------------------------------
# The watermark must not move, so the next successful turn re-delivers what was missed.
python3 -c "
import json
p='$CLAUDE_PLUGIN_DATA/credentials.json'
d=json.load(open(p)); d['endpoint']='http://127.0.0.1:9'; json.dump(d, open(p,'w'))"
turn user "sent while the server was down" u5 >> "$TRANSCRIPT"
fire
missing=$(psql "$DB" -At -c "select count(*) from public.messages m
  join public.conversations c on c.id = m.conversation_id
  where c.session_id = '$SESSION' and m.content like '%server was down%'")
check "nothing stored while down"   0 "$missing"

python3 -c "
import json
p='$CLAUDE_PLUGIN_DATA/credentials.json'
d=json.load(open(p)); d['endpoint']='$BASE'; json.dump(d, open(p,'w'))"
fire
recovered=$(psql "$DB" -At -c "select count(*) from public.messages m
  join public.conversations c on c.id = m.conversation_id
  where c.session_id = '$SESSION' and m.content like '%server was down%'")
check "recovered on the next turn"  1 "$recovered"

total=$(psql "$DB" -At -c "select count(*) from public.messages m
  join public.conversations c on c.id = m.conversation_id where c.session_id = '$SESSION'")
check "no duplicates after recovery" 5 "$total"

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
print(int(max(rounds)))
PY
)
if [ "$latency" -lt 50 ]; then
  printf '  ok   %-46s worst of 12 rounds: %sms\n' "hook returns in under 50ms" "$latency"; pass=$((pass+1))
else
  printf '  FAIL %-46s worst of 12 rounds: %sms\n' "hook returns in under 50ms" "$latency"; fail=$((fail+1))
fi

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
