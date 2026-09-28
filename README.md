# /successor — hand a long Claude Code session to a fresh one

A [Claude Code](https://claude.com/claude-code) skill for people who run their sessions inside
[herdr](https://herdr.dev). When a session gets long, `/successor` retires it into a numbered
successor: `Refactor billing 03` becomes `Refactor billing 04` in a new tab right beside it,
with the same model, effort, permission mode and working directory. The successor starts from a
composed first prompt that carries the work forward, plus a mechanical index of everything you
typed. Then it quits the old session and closes its tab.

The retiring session never compacts, so its transcript keeps your original words, and the
successor is told to read it whenever the first prompt and the record disagree.

Also included: `claude_auto_successor.sh`, a cron job that tells any idle session past 250,000
tokens of context to run `/successor` on its own.

## Requirements

- Claude Code, running inside herdr panes
- `jq` and `python3`
- macOS or Linux (bash)

## Install

```bash
git clone <this repo> ~/claude-successor-skill
mkdir -p ~/.claude/skills
ln -s ~/claude-successor-skill/skills/successor ~/.claude/skills/successor
# put bin/ on PATH — in ~/.bashrc or ~/.zshrc:
export PATH="$HOME/claude-successor-skill/bin:$PATH"
```

Recommended: allow the one command the successor runs as its very first action, so it is never
held at a permission prompt. In `~/.claude/settings.json`:

```json
{ "permissions": { "allow": ["Bash(claude_successor_retire_predecessor.sh:*)"] } }
```

Then type `/successor` in any Claude Code session running in herdr.

## What it does

| Step | What happens |
|---|---|
| 1 | `claude_successor_read_state.sh` reads the session's title, number, model, effort, mode, pane and tab |
| 2 | the session commits its own work |
| 3 | it writes the first prompt, then `claude_successor_first_prompt.py index` appends an index of your turns |
| 4 | it sweeps for loose ends (report-only) and appends them, with a ledger of inherited items and a list of background work |
| 5 | `claude_successor_skill_handover.sh` opens the tab, launches, verifies the launch flags, carries the task list, delivers the first prompt and proves it arrived |
| 6 | the session sends a closing report to the successor and stops; the successor quits it via `claude_successor_retire_predecessor.sh` |

## Configuration

| Variable | Used by | Default |
|---|---|---|
| `CLAUDE_CONFIG_DIR` | all | `~/.claude` |
| `SUCCESSOR_CWD` | read_state | the predecessor's working directory |
| `SUCCESSOR_MODEL` | read_state | the last model deliberately chosen (launch flag or `/model`) |
| `SUCCESSOR_EFFORT` | read_state | the session's current effort |
| `HERDR_SOCKET` | handover (tab placement) | `~/.config/herdr/herdr.sock` |
| `RETIRE_POLL`, `RETIRE_POLLS` | retire_predecessor | 20 s, 90 polls |

## The auto-successor cron

Every run, `claude_auto_successor.sh` looks at every Claude pane in herdr. It tells a session to
run `/successor` when all of these hold:

- the session is idle
- its transcript has not changed for 30 minutes
- the last response's context (input + cache read + cache creation tokens) is over the threshold
- the input box holds no draft

Each session is told at most once, and at most one session per run. The log at
`~/.claude_auto_successor.log` doubles as its memory.

```bash
crontab -e
*/10 * * * * PATH=$HOME/claude-successor-skill/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin claude_auto_successor.sh
```

| Variable | Default |
|---|---|
| `SUCCESSOR_THRESHOLD` | `250000` tokens — set it in the crontab line to change it |
| `SUCCESSOR_IDLE_MIN` | `30` minutes |
| `SUCCESSOR_EXCLUDE` | space-separated session-id prefixes to leave alone |
| `SUCCESSOR_LOG` | `~/.claude_auto_successor.log` |
| `SUCCESSOR_DRY=1` | print what it would do, send nothing |

Why 250k: a fresh successor starts at roughly 30-70k tokens, so it can never trip the threshold
at birth. A lower threshold cut sessions off in the middle of a single large job.

## Other tools

- `herdr_session_manage.sh` — `start`, `quit`, `draft` and `tell` for Claude sessions in herdr
  panes. Each verb checks its own result: `quit` refuses to ctrl+d a pane with an unsent draft,
  and `tell` refuses a pane with a draft, then proves delivery from the target's transcript.
- `claude_copy_task_list_to_successor.py` — copies the open ctrl+t task items to the successor.

## License

MIT — see `LICENSE`.
