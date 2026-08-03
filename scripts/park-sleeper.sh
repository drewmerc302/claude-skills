#!/bin/bash
# park-sleeper: launched as a background task by the overnight-park skill.
# Sleeps in <=55min ticks (inside the ~1h prompt-cache TTL) instead of one
# long sleep to reset — a single multi-hour sleep means zero API turns during
# the park, so the lead session's own prompt cache goes cold and resume pays
# a full transcript re-ingest. Each tick's completion is a real (cheap) turn
# that keeps the cache warm; the skill relaunches this script on every
# "PARK HEARTBEAT" wake until it finally reports "WINDOW RESET".
#
# Usage: park-sleeper.sh <reset_epoch>

RESET="${1:?usage: park-sleeper.sh <reset_epoch>}"
SLACK=120                      # seconds past reset before declaring reset
TICK=3300                      # 55 min — inside the 1h cache TTL with margin
CLAUDE_DIR="$HOME/.claude"
SID="${CLAUDE_CODE_SESSION_ID:-main}"

NOW=$(date +%s)
END=$((RESET + SLACK))
REMAIN=$((END - NOW))

if [ "$REMAIN" -le "$TICK" ]; then
    # Final stretch — sleep the rest of the way and declare reset.
    # caffeinate -is: a parked lead makes no API turns, so Claude Code's own
    # 5-min power assertions lapse and an idle MacBook sleeps mid-park,
    # freezing this timer. Hold an assertion for exactly the sleep window.
    while [ "$(date +%s)" -lt "$END" ]; do
        caffeinate -is sleep 60
    done

    # Post-reset housekeeping:
    # - snooze limit-guard 15 min: cached usage % still shows the old window's
    #   high value until fresh API responses flow in; without this the hook
    #   would re-park immediately on stale data.
    # - remove park-state so the stall watcher stands down.
    echo "$(($(date +%s) + 900))" > "$CLAUDE_DIR/.limit-guard-snooze"
    rm -f "$CLAUDE_DIR/park-state-$SID.json"

    echo "WINDOW RESET at $(date '+%H:%M'). Fresh 5h window active. Resume the parked task now — continue the implementation exactly where the transcript left off. Do not re-plan from scratch."
else
    caffeinate -is sleep "$TICK"
    MIN_LEFT=$(( (END - $(date +%s)) / 60 ))
    echo "PARK HEARTBEAT: still parked, ~${MIN_LEFT} min until reset. Relaunch immediately: ~/.claude/scripts/park-sleeper.sh ${RESET} (Bash, run_in_background:true). Do not do anything else this turn — no status checks, no re-reading state, just relaunch and end the turn."
fi
