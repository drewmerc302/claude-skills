#!/bin/bash
# arm-overnight: called by the /overnight kickoff skill (step 2).
# Writes the per-session armed file the stall-watcher reads, 3 lines:
#   1: epoch armed
#   2: lead claude session pid (found by walking up the process tree)
#   3: run cwd
# Lines 2-3 power the watcher's hard-death revive branch (v3); without them
# it degrades to alert-only, as pre-v3. Also clears this session's stale
# alert/revive flags so a re-arm starts a fresh incident window.

SID="${CLAUDE_CODE_SESSION_ID:-main}"
CLAUDE_DIR="$HOME/.claude"

P=$$; LEAD=""
while [ "$P" -gt 1 ]; do
    C=$(ps -o comm= -p "$P" 2>/dev/null | xargs basename 2>/dev/null)
    if [ "$C" = "claude" ] || [ "$C" = "node" ]; then LEAD="$P"; break; fi
    P=$(ps -o ppid= -p "$P" | tr -d ' ')
done

printf '%s\n%s\n%s\n' "$(date +%s)" "$LEAD" "$PWD" > "$CLAUDE_DIR/overnight-armed-$SID"
rm -f "$CLAUDE_DIR/.stall-alerted-$SID" "$CLAUDE_DIR/.revive-attempted-$SID"
echo "armed: sid=$SID lead_pid=${LEAD:-unknown} cwd=$PWD"
