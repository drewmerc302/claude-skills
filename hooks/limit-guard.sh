#!/bin/bash
# limit-guard: PostToolUse hook (matcher "*").
# Parks long agentic runs before the 5h subscription cap kills them, and
# stops cleanly when the 7d cap is the binding constraint.
#
# Sensor: ~/.claude/usage-cache.json, written by statusline-command.sh from
# the native rate_limits block in the statusline stdin JSON.
#
# State files (all in ~/.claude), session-scoped by $CLAUDE_CODE_SESSION_ID
# (falls back to "main") so concurrent overnight runs in different
# projects/terminals don't clobber each other's park state:
#   .limit-guard-last-check-<sid>  epoch of last check (throttle)
#   .limit-guard-snooze            epoch until which the guard stays silent
#                                  (global — a snooze after resume/veto is
#                                  meant to cover the whole machine's stale
#                                  cache window, not just one session)
#   park-state-<sid>.json          present while that session's park is live

HOOK_INPUT=$(cat)   # hook stdin: JSON with session_id, cwd, tool_name, ...
SID=$(echo "$HOOK_INPUT" | jq -r '.session_id // empty' 2>/dev/null)
[ -z "$SID" ] && SID="${CLAUDE_CODE_SESSION_ID:-main}"

CLAUDE_DIR="$HOME/.claude"
CACHE="$CLAUDE_DIR/usage-cache.json"
LAST_FILE="$CLAUDE_DIR/.limit-guard-last-check-$SID"
SNOOZE_FILE="$CLAUDE_DIR/.limit-guard-snooze"
PARK_STATE="$CLAUDE_DIR/park-state-$SID.json"

THROTTLE=300      # seconds between real checks
MAX_STALE=600     # ignore cache older than this — never park on stale data
FIVE_THRESH=85    # 5h park threshold (%)
WEEK_THRESH=70    # 7d clean-stop threshold (%)

NOW=$(date +%s)

# Optional time-boxed override of the 7d threshold, for a week where the normal
# stop point is too conservative. File format, one line: "<expiry_epoch> <pct>".
# It EXPIRES ON ITS OWN — past the epoch the guard silently returns to
# WEEK_THRESH, so raising the bar for one week can't quietly become permanent.
WEEK_OVERRIDE_FILE="$CLAUDE_DIR/.limit-guard-week-thresh"
if [ -f "$WEEK_OVERRIDE_FILE" ]; then
    read -r OV_EXP OV_PCT < "$WEEK_OVERRIDE_FILE"
    case "$OV_EXP$OV_PCT" in
        *[!0-9]*|"") ;;                       # malformed -> ignore, keep the default
        *)
            if [ "$NOW" -lt "$OV_EXP" ] && [ "$OV_PCT" -ge 1 ] && [ "$OV_PCT" -le 100 ]; then
                WEEK_THRESH="$OV_PCT"
            else
                rm -f "$WEEK_OVERRIDE_FILE"   # expired or out of range: clean up
            fi
            ;;
    esac
fi

LAST=$(cat "$LAST_FILE" 2>/dev/null || echo 0)
[ "$((NOW - LAST))" -lt "$THROTTLE" ] && exit 0
echo "$NOW" > "$LAST_FILE"

[ -f "$CACHE" ] || exit 0

TS=$(jq -r '.ts // 0' "$CACHE" 2>/dev/null || echo 0)
[ "$((NOW - TS))" -gt "$MAX_STALE" ] && exit 0

SNOOZE=$(cat "$SNOOZE_FILE" 2>/dev/null || echo 0)
[ "$NOW" -lt "$SNOOZE" ] && exit 0

# A park-state whose reset has long passed is stale (e.g. a session that never
# cleaned up on resume) and must not silence the guard forever — 2026-07-15 bug.
if [ -f "$PARK_STATE" ]; then
    PARK_RST=$(jq -r '.reset_epoch // 0' "$PARK_STATE" 2>/dev/null || echo 0)
    if [ "$NOW" -gt "$((PARK_RST + 1800))" ]; then
        rm -f "$PARK_STATE"
    else
        exit 0
    fi
fi

FIVE=$(jq -r '.rate_limits.five_hour.used_percentage // 0' "$CACHE" | cut -d. -f1)
WEEK=$(jq -r '.rate_limits.seven_day.used_percentage // 0' "$CACHE" | cut -d. -f1)
FIVE_RST=$(jq -r '.rate_limits.five_hour.resets_at // 0' "$CACHE")
WEEK_RST=$(jq -r '.rate_limits.seven_day.resets_at // 0' "$CACHE")

inject() {
    jq -n --arg ctx "$1" \
        '{hookSpecificOutput:{hookEventName:"PostToolUse",additionalContext:$ctx}}'
    exit 0
}

if [ "$WEEK" -ge "$WEEK_THRESH" ]; then
    WEEK_HUMAN=$(date -r "$WEEK_RST" '+%a %b %d %H:%M' 2>/dev/null || echo "unknown")
    inject "LIMIT GUARD (7d): weekly usage at ${WEEK}% — the weekly cap is binding, parking for a 5h reset is pointless. Read and follow ~/.claude/skills/overnight-park/SKILL.md, mode weekly-stop, pct ${WEEK}, reset_epoch ${WEEK_RST} (resets ${WEEK_HUMAN}). Finish only the current atomic step, then stop cleanly per the skill."
fi

if [ "$FIVE" -ge "$FIVE_THRESH" ]; then
    FIVE_HUMAN=$(date -r "$FIVE_RST" '+%H:%M' 2>/dev/null || echo "unknown")
    inject "LIMIT GUARD (5h): usage at ${FIVE}%, hard cap near. Read and follow ~/.claude/skills/overnight-park/SKILL.md, mode park, pct ${FIVE}, reset_epoch ${FIVE_RST} (resets ${FIVE_HUMAN}). Park NOW before starting any new work."
fi

exit 0
