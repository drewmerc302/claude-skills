#!/usr/bin/env bash
# orphan-agents.sh — find subagents that have stopped working but never terminated.
#
# THE FAILURE THIS DETECTS
#
# A subagent spawned with a `name` is an addressable teammate. If it delivers its result via
# SendMessage and then ends its turn, it does NOT exit — it parks, waiting for a reply that never
# comes. The background-task panel keeps counting wall-clock, so five finished gates looked like
# five running ones for four and a quarter hours (Rhapsode, 2026-08-06).
#
# The counter is time since spawn, not evidence of work. The transcript mtime IS that evidence:
# a live agent writes to its .jsonl constantly, an orphan has not written in hours.
#
# Usage:  orphan-agents.sh [idle_minutes]     (default 15)
#
# Prints one line per suspected orphan. Kill them from the session with:
#     TaskStop({task_id: "<agent-name>"})
# Names come from the file: `agent-a<name>-<hash>.jsonl` -> `<name>`.
set -uo pipefail
IDLE_MIN="${1:-15}"
PROJECTS="$HOME/.claude/projects"

[ -d "$PROJECTS" ] || { echo "no ~/.claude/projects"; exit 0; }

now=$(date +%s)
found=0

# Only sessions touched today are worth scanning; anything older is long dead and not "cruft the
# panel is still showing."
while IFS= read -r f; do
  # BSD stat first (macOS), GNU second (Linux) — the rest of this script is portable and
  # there is no reason for one flag to pin it to one OS.
  mtime=$(stat -f %m "$f" 2>/dev/null || stat -c %Y "$f" 2>/dev/null) || continue
  [ -n "$mtime" ] || continue
  idle=$(( (now - mtime) / 60 ))
  [ "$idle" -ge "$IDLE_MIN" ] || continue

  base=$(basename "$f" .jsonl)          # agent-a<name>-<hash>
  name=$(printf '%s' "$base" | sed -E 's/^agent-a?//; s/-[0-9a-f]{8,}$//')
  # A transcript whose last line is an assistant turn ended cleanly and is just sitting there.
  # One ending mid-tool-use is a different animal — it may have died hard.
  tail_type=$(tail -1 "$f" 2>/dev/null | python3 -c 'import json,sys
try: print(json.loads(sys.stdin.read()).get("type","?"))
except Exception: print("unparsed")' 2>/dev/null)

  printf 'IDLE %4dm  %-24s  last=%-9s  %s\n' "$idle" "$name" "$tail_type" "$f"
  found=$((found + 1))
done < <(find "$PROJECTS" -path '*/subagents/*.jsonl' -mtime -1 2>/dev/null)

if [ "$found" -eq 0 ]; then
  echo "no orphaned subagents idle >= ${IDLE_MIN}m"
else
  echo
  echo "$found suspected orphan(s). Stop each with TaskStop({task_id: \"<name>\"})."
  echo "If any is genuinely mid-work, its transcript would be growing — re-run to confirm."
  echo
  echo "NOTE: this reads transcripts on disk, not the process table, so it cannot tell an"
  echo "orphan from one already stopped this session — a stopped agent's .jsonl stays put and"
  echo "keeps showing up here. TaskStop on an already-stopped agent is harmless, so prefer"
  echo "re-stopping over skipping. Idle is evidence of nothing happening, not of a live process."
fi
