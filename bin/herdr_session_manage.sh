#!/usr/bin/env bash
# Reach a Claude Code session inside a herdr pane: start one in a new tab, quit one, read its input
# box, or get a message into it. Each verb verifies its own result rather than trusting the call
# that made it.
#
#   herdr_session_manage.sh start <tab-label> [--workspace W] [--cwd PATH] [--agent-name NAME]
#                                             [--session-name TITLE] [--model M] [--effort E]
#                                             [--permission-mode MODE]
#   herdr_session_manage.sh quit  <PANE> [--keep-work]
#   herdr_session_manage.sh draft <PANE>
#   herdr_session_manage.sh tell  <UUID|PANE> <message> [--timeout MS]
#
# tell exit codes: 0 delivered and PROVED off the target's transcript; 1 refused before sending, or
# something arrived that is not what was sent; 2 usage; 3 SENT but not confirmed inside the verify
# budget (TELL_VERIFY_SECONDS, default 30). Treat 3 as probably-delivered: read the target's
# transcript, and never resend blind — that double-prompts a session already acting on the first copy.
#
# Why each verb is not a one-liner:
#   start  `agent start` races the new pane's shell and is refused with agent_pane_busy until the
#          shell is up, so only that error is retried. --model and --effort fail SOFT in claude (an
#          unknown value prints one stderr line and the session runs on the default), so the footer
#          is read back and a verbatim echo of the model name is reported.
#   quit   ctrl+d must arrive twice inside Claude Code's confirm window, and never into a pane
#          holding an unsent draft. A session with background work answers ctrl+d with a menu; the
#          option number is read off the screen rather than assumed.
#   draft  the input box is read in ANSI, because an empty box is not blank: Claude Code paints a
#          dim placeholder suggestion there that a plain-text read reports as typed text.
#   tell   `herdr agent prompt` APPENDS to whatever is already in the input box and submits both,
#          so a send into a pane holding a draft would submit the user's draft for them — refused.
#          Delivery is then proved by reading the TARGET'S transcript, because a send returning 0
#          proves only that herdr accepted a string.
set -uo pipefail

CLAUDE_HOME="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"

usage() { sed -n '2,/^# tell exit codes/p' "$0" | sed -e '$d' -e 's/^# \{0,1\}//' >&2; }
die() { echo "herdr_session_manage: $*" >&2; exit 1; }
die_usage() { echo "herdr_session_manage: $*" >&2; echo >&2; usage; exit 2; }
need() { command -v "$1" >/dev/null 2>&1 || die "missing dependency: $1"; }
need herdr; need python3

api() { herdr "$@" 2>&1; }
jget() { python3 -c 'import json,sys
d=json.load(sys.stdin)
if "error" in d: sys.exit(3)
cur=d.get("result",{})
for k in sys.argv[1].split("."):
    if cur is None: sys.exit(4)
    cur=cur.get(k) if isinstance(cur,dict) else None
print(cur if cur is not None else "")' "$1"; }

# ---------------------------------------------------------------- the input box
# The box is what sits between the LAST two ─── rules. A pane caught mid-repaint shows no rules at
# all, and one read reports "no input box" on a healthy pane, so exit 2 (could not look) is retried
# and only a run of unreadable reads is reported as unreadable. A box holding text is never retried.
pane_draft() {
  local i out rc
  for i in 1 2 3 4 5; do
    out=$(pane_draft_once "$1"); rc=$?
    [ "$rc" = 2 ] || { printf '%s' "$out"; return "$rc"; }
    sleep 1
  done
  echo "pane_draft: $1 showed no input box in 5 reads over 5s. What was on screen:" >&2
  herdr pane read "$1" --source visible --lines 20 --format text 2>&1 | sed 's/^/  | /' >&2
  return 2
}
pane_draft_once() {
  herdr pane read "$1" --source visible --lines 60 --format ansi --ansi 2>/dev/null | python3 -c '
import re,sys
raw=sys.stdin.read().split("\n")
plain=[re.sub(r"\x1b\[[0-9;]*[A-Za-z]","",l).replace("\r","") for l in raw]
rules=[i for i,l in enumerate(plain) if l.strip().startswith("─")]
# The top border carries the session title right-aligned, so a title long enough to fill the pane
# eats the dash run and only the bottom rule is found. Recover the top border from the input line.
if len(rules)<2:
    p=[i for i,l in enumerate(plain[:rules[-1]]) if l.startswith("❯")] if rules else []
    if p and p[-1]>0: rules=[p[-1]-1]+rules
if len(rules)<2: sys.exit(2)
out=[]
for r,p in zip(raw[rules[-2]+1:rules[-1]], plain[rules[-2]+1:rules[-1]]):
    body=re.sub(r"^\s*❯\s?","",p).strip()
    if not body: continue
    if "\x1b[2m" in r: continue          # dim = placeholder suggestion, not typed text
    out.append(body)
sys.stdout.write("\n".join(out))'
}

# Foreground process command line of a pane, empty if the pane is gone. A freshly created pane
# lists its process before cmdline is filled in, so fall back through the other names for it.
pane_shell_cmd() {
  herdr pane process-info --pane "$1" 2>/dev/null | python3 -c '
import json,sys
try: p=json.load(sys.stdin)["result"]["process_info"]["foreground_processes"]
except Exception: sys.exit(1)
if not p: print(""); raise SystemExit
e=p[0]
print(e.get("cmdline") or e.get("argv0") or e.get("name") or "")' 2>/dev/null
}

pane_model() {  # the model+effort field of the statusline footer, empty if it has not painted yet
  local i out
  for i in 1 2 3 4 5; do
    out=$(herdr pane read "$1" --source visible --lines 12 --format text 2>/dev/null |
          sed -n 's/^ *[^ |]* | \([^|]*\) |.*/\1/p' | tail -1)
    out="${out%"${out##*[![:space:]]}"}"
    [ -n "$out" ] && { printf '%s' "$out"; return; }
    sleep 1
  done
}
warn_model() {  # <pane> <requested model> — a model the CLI knows is rendered as a display name;
  local shown s; shown=$(pane_model "$1"); s="$shown"   # one it does not know is echoed verbatim
  s="${s% xhigh}"; s="${s% max}"; s="${s% high}"; s="${s% medium}"; s="${s% low}"
  if [ -n "$shown" ] && [ "$s" = "$2" ]; then
    echo "WARNING: the footer echoes '$2' back verbatim — the CLI does not know that model" >&2
  fi
}

pane_session_uuid() {  # the session id herdr reports for a pane, empty if no live agent
  herdr pane list --workspace "${1%%:*}" 2>/dev/null | python3 -c '
import json,sys
pid=sys.argv[1]
try: panes=json.load(sys.stdin)["result"]["panes"]
except Exception: raise SystemExit(0)
for p in panes:
    if p.get("pane_id")==pid: print((p.get("agent_session") or {}).get("value") or "")' "$1"
}
agent_status_of() {
  herdr agent list 2>/dev/null | python3 -c '
import json,sys
pid=sys.argv[1]
for a in json.load(sys.stdin).get("result",{}).get("agents",[]):
    if a.get("pane_id")==pid: print(a.get("agent_status") or "")' "$1"
}
pane_of_uuid() {  # matched on the session id, never a remembered pane: a pane id names a LOCATION
  herdr agent list 2>/dev/null | python3 -c '
import json,sys
u=sys.argv[1]
for a in json.load(sys.stdin).get("result",{}).get("agents",[]):
    if ((a.get("agent_session") or {}).get("value") or "")==u: print(a.get("pane_id") or "")' "$1"
}
transcript_path() {  # <uuid> -> its transcript, in any project folder, empty if none yet
  local f
  for f in "$CLAUDE_HOME"/projects/*/"$1".jsonl; do [ -f "$f" ] && { printf '%s' "$f"; return 0; }; done
  return 1
}

# ---------------------------------------------------------------- quit
cmd_quit() {
  local pane="${1:-}"; [ -n "$pane" ] || die_usage "quit needs a pane id"; shift
  local keep_work=; while [ $# -gt 0 ]; do case "$1" in --keep-work) keep_work=1;; *) die_usage "quit: unknown option $1";; esac; shift; done
  local draft rc; draft=$(pane_draft "$pane"); rc=$?
  # exit 2 is "could not find the input box", which is NOT "there is no draft"
  [ "$rc" = 2 ] && die "quit: cannot read the input box in $pane — refusing to send ctrl+d"
  if [ -n "$draft" ]; then
    echo "REFUSED: $pane holds an unsent draft — not quitting. Its text:" >&2
    printf '%s\n' "$draft" >&2
    exit 1
  fi
  herdr pane send-keys "$pane" ctrl+d ctrl+d >/dev/null 2>&1   # both in ONE call: a 1s gap does not exit
  # Success is the pane being back at a SHELL, not merely "not claude": mid-turn the foreground
  # process can be one of claude's own children.
  local i cmd screen n answered=
  for i in 1 2 3 4 5 6 7 8 9 10 11 12; do
    sleep 1; cmd=$(pane_shell_cmd "$pane")
    case "${cmd##*/}" in -bash|bash|-zsh|zsh|sh|-sh|fish|-fish) echo "quit: $pane is back at $cmd"; return 0;; esac
    # Background work makes ctrl+d open a menu. Default answer: stop the tasks. "Move to
    # background" forks the session into a daemon-owned copy under a new id that nothing addresses.
    [ -n "$answered" ] && continue
    screen=$(herdr pane read "$pane" --source visible --lines 40 --format text 2>/dev/null)
    case "$screen" in *"Background work is running"*) ;; *) continue;; esac
    local want="Exit and stop tasks"; [ -n "$keep_work" ] && want="Move to background and exit"
    n=$(printf '%s\n' "$screen" | sed -n "s/^[^0-9]*\([0-9]\)\. *$want.*/\1/p" | head -1)
    [ -n "$n" ] || die "quit: $pane holds background work and offers no '$want' option — left untouched"
    herdr pane send-keys "$pane" "$n" >/dev/null 2>&1
    answered=$n
    echo "quit: $pane had background work — chose $n, $want" >&2
  done
  die "quit: $pane still running claude after 12s — nothing was forced"
}

# ---------------------------------------------------------------- draft
cmd_draft() {
  local pane="${1:-}"; [ -n "$pane" ] || die_usage "draft needs a pane id"
  local d rc; d=$(pane_draft "$pane"); rc=$?
  [ "$rc" = 2 ] && { echo "unreadable: no input box found in $pane" >&2; return 2; }
  [ -z "$d" ] && { echo "empty"; return 0; }
  printf '%s\n' "$d"; return 1
}

# ---------------------------------------------------------------- start
cmd_start() {
  local label="" ws="" cwd="${SUCCESSOR_CWD:-$PWD}" aname="" sname="" model="" effort="" tmo=120000 pmode="default"
  label="${1:-}"; shift || true
  [ -n "$label" ] || die_usage "start needs a tab label"
  case "$label" in -*) die_usage "start: '$label' looks like a switch, not a tab label";; esac
  while [ $# -gt 0 ]; do
    case "$1" in
      --workspace) ws="$2"; shift 2;;
      --cwd) cwd="$2"; shift 2;;
      --agent-name) aname="$2"; shift 2;;
      --session-name) sname="$2"; shift 2;;
      --model) model="$2"; shift 2;;
      --effort) effort="$2"; shift 2;;
      --permission-mode) pmode="$2"; shift 2;;
      --timeout) tmo="$2"; shift 2;;
      *) die "start: unknown option $1";;
    esac
  done
  case "$pmode" in auto|default|acceptEdits|bypassPermissions|dontAsk|plan) ;;
    *) die "start: --permission-mode '$pmode' is not a mode claude accepts";;
  esac
  [ -n "$aname" ] || aname="s$(date +%H%M%S)"
  [[ "$aname" =~ ^[a-z][a-z0-9_-]{0,31}$ ]] || die "agent name '$aname' fails herdr's [a-z][a-z0-9_-]{0,31}"

  local -a a=(tab create --label "$label" --no-focus --cwd "$cwd")
  [ -n "$ws" ] && a+=(--workspace "$ws")
  local out; out=$(api "${a[@]}") || die "tab create failed: $out"
  local pane tab
  pane=$(printf '%s' "$out" | jget root_pane.pane_id); tab=$(printf '%s' "$out" | jget tab.tab_id)
  [ -n "$pane" ] && [ -n "$tab" ] || die "tab create returned no pane/tab ($out)"
  local i
  for i in $(seq 1 20); do [ -n "$(pane_shell_cmd "$pane")" ] && break; sleep 0.5; done
  [ -n "$(pane_shell_cmd "$pane")" ] || { herdr tab close "$tab" >/dev/null 2>&1; die "pane $pane never reached a shell"; }

  local -a extra=(--permission-mode "$pmode")
  [ -n "$model" ] && extra+=(--model "$model")
  [ -n "$effort" ] && extra+=(--effort "$effort")
  [ -n "$sname" ] && extra+=(--name "$sname")      # the session title, set at birth
  for i in 1 2 3; do
    out=$(api agent start "$aname" --kind claude --pane "$pane" --timeout "$tmo" -- "${extra[@]}")
    grep -q agent_pane_busy <<<"$out" || break
    sleep 2
  done
  grep -q '"result"' <<<"$out" || die "agent start failed: $out"
  local uuid; uuid=$(printf '%s' "$out" | jget agent.agent_session.value)
  [ -n "$uuid" ] || die "agent started but herdr reports no session id"
  [ -n "$model" ] && warn_model "$pane" "$model"
  echo "pane=$pane tab=$tab agent=$aname uuid=$uuid"
}

# ---------------------------------------------------------------- tell
# Waits on herdr's own agent_status, then READS THE STATUS BACK and judges that: `agent wait` can
# return on a state that has since moved on.
wait_ready() {
  local st="" i
  for i in 1 2 3 4 5; do
    herdr agent wait "$1" --until idle --until done --timeout "$2" >/dev/null 2>&1
    st=$(agent_status_of "$1")
    [ -n "$st" ] && break
    sleep 1
  done
  printf '%s' "$st"
  case "$st" in idle|done) return 0;; *) return 1;; esac
}

cmd_tell() {
  local target="${1:-}" msg="${2:-}" tmo=300000
  shift 2 2>/dev/null || true
  [ -n "$target" ] || die_usage "tell needs a target — a session UUID, or a pane id"
  [ -n "$msg" ]    || die_usage "tell needs a message"
  case "$msg" in --*) die_usage "tell: the message comes BEFORE the options — '$msg' looks like a flag";; esac
  while [ $# -gt 0 ]; do
    case "$1" in
      --timeout) tmo="$2"; [[ "$tmo" =~ ^[0-9]+$ ]] || die_usage "tell: --timeout takes milliseconds"; shift 2;;
      *) die "tell: unknown option $1";;
    esac
  done
  local uuid="" pane=""
  if [[ "$target" =~ ^[0-9a-f-]{36}$ ]]; then uuid="$target"; pane=$(pane_of_uuid "$uuid")
  else pane="$target"; uuid=$(pane_session_uuid "$pane")
  fi
  [ -n "$pane" ] && [ -n "$uuid" ] || die "tell: $target is not a live session in herdr — nothing was sent"
  [ "${CLAUDE_CODE_SESSION_ID:-}" != "$uuid" ] || die "tell: $uuid is THIS session — refusing to prompt myself"

  local st rc; st=$(wait_ready "$pane" "$tmo"); rc=$?
  [ "$st" = blocked ] && die "tell: $pane is BLOCKED on a question it needs answered — nothing was sent"
  [ "$rc" = 0 ] || die "tell: $pane settled at '${st:-<no live agent>}' rather than idle — nothing was sent"
  local draft drc; draft=$(pane_draft "$pane"); drc=$?
  [ "$drc" = 2 ] && die "tell: cannot read the input box in $pane — refusing to send"
  [ -z "$draft" ] || die "tell: $pane holds unsent text — refusing to send, it would be submitted with the message"

  # Baseline BEFORE the send, so only a record written after it can match. A session that has never
  # taken a turn has no transcript yet, so the path is re-resolved on every read below.
  local tr before=0; tr=$(transcript_path "$uuid") || tr=""
  [ -f "$tr" ] && before=$(wc -l < "$tr" | tr -d ' ')
  herdr agent prompt "$pane" "$msg" --wait --until working --timeout 30000 >/dev/null 2>&1

  local verdict
  verdict=$(TELL_VERIFY_SECONDS="${TELL_VERIFY_SECONDS:-30}" python3 - "$uuid" "$before" "$msg" "$CLAUDE_HOME" <<'PY' 2>&1
import glob, hashlib, json, os, sys, time
uuid, before, msg, home = sys.argv[1], int(sys.argv[2]), sys.argv[3].rstrip("\n"), sys.argv[4]
budget = float(os.environ.get("TELL_VERIFY_SECONDS", "30"))
def escape(s):   # how Claude Code stores a literal mention of its paste tag INSIDE a paste
    return s.replace("</pasted_content", "<\\/pasted_content").replace("<pasted_content", "<\\pasted_content")
def humans():
    out = []
    for p in glob.glob(os.path.join(home, "projects", "*", uuid + ".jsonl")):
        with open(p, encoding="utf-8") as f:
            for n, line in enumerate(f, 1):
                if n <= before: continue
                try: r = json.loads(line)
                except Exception: continue
                if r.get("type") != "user" or r.get("isMeta"): continue
                c = r.get("message", {}).get("content")
                t = (c if isinstance(c, str) else "".join(b.get("text", "") for b in c if isinstance(b, dict))).rstrip("\n")
                if t.startswith("<system-reminder>"): continue
                if t.lstrip().startswith("<pasted_content ") and "</pasted_content" in t:   # a long prompt is recorded as a paste
                    t = t.lstrip(); t = t[t.index(">") + 1:]; t = t[:t.rfind("</pasted_content")].strip("\n")
                out.append((n, t))
    return out
h = lambda s: hashlib.md5(s.encode()).hexdigest()
t0 = time.time()
while True:
    cands = humans()
    hit = next((n for n, t in cands if t in (msg, escape(msg))), None)
    if hit is not None or time.time() - t0 >= budget: break
    time.sleep(0.5)
control = msg[:-1] + ("X" if msg[-1:] != "X" else "Y")      # the finder must NOT find a mutated copy
ctrl = next((n for n, t in cands if t in (control, escape(control))), None)
if ctrl is not None: raise SystemExit("VERDICT_BLIND the finder matched a mutated copy, so its positive proves nothing")
if hit is not None: print(f"record={hit} md5={h(msg)}"); raise SystemExit(0)
if cands: raise SystemExit("VERDICT_CORRUPT a new human record arrived but none matches what was sent")
raise SystemExit("VERDICT_UNCONFIRMED nothing has been written to the transcript yet")
PY
)
  if grep -q '^record=' <<<"$verdict"; then
    echo "pane=$pane uuid=$uuid status=$st $(grep '^record=' <<<"$verdict")"; return 0
  fi
  printf '%s\n' "$verdict" >&2
  if grep -q VERDICT_UNCONFIRMED <<<"$verdict"; then
    echo "herdr_session_manage: tell: SENT to $uuid but NOT CONFIRMED — read its transcript before resending" >&2
    exit 3
  fi
  die "tell: the message did not arrive intact in $uuid — treat it as NOT delivered"
}

case "${1:-}" in
  start) shift; cmd_start "$@";;
  quit)  shift; cmd_quit "$@";;
  draft) shift; cmd_draft "$@";;
  tell)  shift; cmd_tell "$@";;
  *) usage; exit 2;;
esac
