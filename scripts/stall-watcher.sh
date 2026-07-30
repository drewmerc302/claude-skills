#!/bin/bash
# stall-watcher: LaunchAgent, runs every 5 min.
# Alerts via iMessage when an ARMED overnight run goes quiet — i.e. likely
# stalled on a permission prompt or died at the hard rate-limit cap.
#
# v2: multi-session. Armed state is per-session: ~/.claude/overnight-armed-<sid>
# (written by the /overnight kickoff skill, removed on completion/stop). Loops
# every armed session independently — one session parked/stalled doesn't mask
# or false-positive another session running in a different project/terminal.
# A live park for that session (park-state-<sid>.json within reset+grace)
# suppresses alerts for it: parked-quiet is fine, stalled-quiet is not.

CLAUDE_DIR="$HOME/.claude"
QUIET_MIN=25     # minutes of transcript silence that count as a stall
PARK_GRACE=900   # seconds past park reset before quiet counts as stall again
NOW=$(date +%s)

shopt -s nullglob
for ARMED in "$CLAUDE_DIR"/overnight-armed-*; do
    SID="${ARMED##*overnight-armed-}"
    PARK_STATE="$CLAUDE_DIR/park-state-$SID.json"
    ALERT_FLAG="$CLAUDE_DIR/.stall-alerted-$SID"

    if [ -f "$PARK_STATE" ]; then
        RESET=$(jq -r '.reset_epoch // 0' "$PARK_STATE" 2>/dev/null || echo 0)
        [ "$NOW" -lt "$((RESET + PARK_GRACE))" ] && continue
    fi

    # This session's own transcript file is named <sid>.jsonl somewhere under
    # projects/ — check its mtime, not "any transcript anywhere" (that masked
    # a stalled session behind an active unrelated one pre-v2).
    RECENT=$(find "$CLAUDE_DIR/projects" -name "${SID}.jsonl" -mmin "-$QUIET_MIN" 2>/dev/null | head -1)
    if [ -n "$RECENT" ]; then
        rm -f "$ALERT_FLAG"
        continue
    fi

    # Quiet too long while armed and not parked -> alert once per incident.
    [ -f "$ALERT_FLAG" ] && continue
    touch "$ALERT_FLAG"
    "$CLAUDE_DIR/scripts/imessage-self.sh" "⚠️ Claude overnight run (session ${SID:0:8}): no activity for ${QUIET_MIN}+ min and no active park. Likely stalled on a permission prompt or died at the hard cap."
done
