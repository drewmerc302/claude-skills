#!/bin/bash
# stall-watcher: LaunchAgent, runs every 5 min.
# Alerts via iMessage when an ARMED overnight run goes quiet — i.e. likely
# stalled on a permission prompt — and REVIVES a run whose lead process died
# hard (crash, kill, OOM: armed, quiet, pid gone, no live park).
#
# v2: multi-session. Armed state is per-session: ~/.claude/overnight-armed-<sid>
# (written by the /overnight kickoff skill, removed on completion/stop). Loops
# every armed session independently — one session parked/stalled doesn't mask
# or false-positive another session running in a different project/terminal.
# A live park for that session (park-state-<sid>.json within reset+grace)
# suppresses alerts for it: parked-quiet is fine, stalled-quiet is not.
#
# v3: hard-death watchdog. The kickoff skill now writes 3 lines to the armed
# file: <epoch> / <lead claude pid> / <run cwd>. If a quiet session's lead pid
# is dead, the watcher resumes the session non-interactively with a
# reconcile-the-ledger prompt instead of just alerting. Old 1-line armed files
# degrade to alert-only. ONE auto-revive per armed session per run — the
# .revive-attempted flag is only cleared by the skill's disarm step, never by
# activity, so a crash-revive-crash loop can't ping-pong all night.

CLAUDE_DIR="$HOME/.claude"
QUIET_MIN=25     # minutes of transcript silence that count as a stall
PARK_GRACE=900   # seconds past park reset before quiet counts as stall again
CLAUDE_BIN="${STALL_WATCHER_CLAUDE_BIN:-claude}"   # test seam
NOW=$(date +%s)

REVIVE_PROMPT="REVIVED BY HARD-DEATH WATCHDOG: your previous overnight session process died. Before doing anything else, reconcile docs/overnight-gates/ledger.md against git status and git log per ~/.claude/skills/overnight/SKILL.md — stale IN_FLIGHT or VERIFIED rows must be corrected to match reality first. Then continue the run from the ledger's true state. All overnight rules still apply, including the completion/disarm protocol."

shopt -s nullglob
for ARMED in "$CLAUDE_DIR"/overnight-armed-*; do
    SID="${ARMED##*overnight-armed-}"
    PARK_STATE="$CLAUDE_DIR/park-state-$SID.json"
    ALERT_FLAG="$CLAUDE_DIR/.stall-alerted-$SID"
    REVIVE_FLAG="$CLAUDE_DIR/.revive-attempted-$SID"

    if [ -f "$PARK_STATE" ]; then
        RESET=$(jq -r '.reset_epoch // 0' "$PARK_STATE" 2>/dev/null || echo 0)
        [ "$NOW" -lt "$((RESET + PARK_GRACE))" ] && continue
    fi

    # This session's own transcript file is named <sid>.jsonl somewhere under
    # projects/ — check its mtime, not "any transcript anywhere" (that masked
    # a stalled session behind an active unrelated one pre-v2).
    RECENT=$(find "$CLAUDE_DIR/projects" -name "${SID}.jsonl" -mmin "-$QUIET_MIN" 2>/dev/null | head -1)
    if [ -n "$RECENT" ]; then
        rm -f "$ALERT_FLAG"   # NOT the revive flag — one auto-revive per run
        continue
    fi

    # Quiet too long while armed and not (freshly) parked. Decide: dead or stalled?
    LEAD_PID=$(sed -n '2p' "$ARMED" 2>/dev/null)
    RUN_CWD=$(sed -n '3p' "$ARMED" 2>/dev/null)

    LEAD_DEAD=0
    if [ -n "$LEAD_PID" ]; then
        COMM=$(ps -o comm= -p "$LEAD_PID" 2>/dev/null | xargs basename 2>/dev/null)
        # pid gone, or recycled to some unrelated process -> the lead is dead
        if [ "$COMM" != "claude" ] && [ "$COMM" != "node" ]; then
            LEAD_DEAD=1
        fi
    fi

    if [ "$LEAD_DEAD" = "1" ] && [ "$SID" != "main" ] && [ -d "$RUN_CWD" ] && [ ! -f "$REVIVE_FLAG" ]; then
        touch "$REVIVE_FLAG"
        # Mirror park-sleeper's post-reset housekeeping: a leftover park-state
        # would suppress the next watcher pass, and stale cached usage % would
        # make limit-guard re-park the revived session instantly.
        rm -f "$PARK_STATE"
        echo "$((NOW + 900))" > "$CLAUDE_DIR/.limit-guard-snooze"
        (
            cd "$RUN_CWD" || exit 1
            nohup "$CLAUDE_BIN" -p --resume "$SID" --permission-mode acceptEdits \
                "$REVIVE_PROMPT" >> "$CLAUDE_DIR/revive-$SID.log" 2>&1 &
        )
        "$CLAUDE_DIR/scripts/imessage-self.sh" "🩹 Claude overnight run (session ${SID:0:8}): lead process died; watchdog resumed it. Log: ~/.claude/revive-${SID:0:8}*.log" 2>/dev/null
        continue
    fi

    # Alive-but-quiet (or un-revivable): alert once per incident, as before.
    [ -f "$ALERT_FLAG" ] && continue
    touch "$ALERT_FLAG"
    "$CLAUDE_DIR/scripts/imessage-self.sh" "⚠️ Claude overnight run (session ${SID:0:8}): no activity for ${QUIET_MIN}+ min and no active park. Likely stalled on a permission prompt or died at the hard cap."
done
