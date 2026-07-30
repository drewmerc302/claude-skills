#!/bin/bash
# Alert-to-self. Usage: imessage-self.sh "message text"
#
# 1. Always append to ~/.claude/alerts.log
# 2. Try iMessage to self (Messages AppleScript, 15s timeout)
#    - requires one-time Automation grant: System Settings > Privacy &
#      Security > Automation > <your terminal> > Messages
# 3. On failure: local macOS notification (Notification Center) so the
#    alert is at least visible on the Mac. No external services.
#
# Recipient comes from the IMSG_TARGET env var — set it in your shell profile:
#   export IMSG_TARGET="you@example.com"    # or a phone number
# Left unset, the script still logs and shows a local notification; it just
# can't reach your phone.

TARGET="${IMSG_TARGET:-}"
MSG="${1:?usage: imessage-self.sh <message>}"
LOG="$HOME/.claude/alerts.log"

echo "$(date '+%Y-%m-%d %H:%M:%S') $MSG" >> "$LOG"

if [ -n "$TARGET" ] && osascript - "$TARGET" "$MSG" <<'EOF' 2>>"$LOG"
on run argv
    set theTarget to item 1 of argv
    set theMsg to item 2 of argv
    with timeout of 15 seconds
        tell application "Messages"
            set targetService to 1st account whose service type = iMessage
            set targetBuddy to participant theTarget of targetService
            send theMsg to targetBuddy
        end tell
    end timeout
end run
EOF
then
    exit 0
fi

# Fallback: local notification only (phone unreachable until the
# Automation permission above is granted).
osascript -e 'on run argv' \
    -e 'display notification (item 1 of argv) with title "Claude overnight guard"' \
    -e 'end run' -- "$MSG" 2>>"$LOG"
exit 0
