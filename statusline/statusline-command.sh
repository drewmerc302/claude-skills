#!/bin/bash
input=$(cat)

# Tee rate-limit snapshot for the limit-guard hook (atomic write; skip if absent)
if echo "$input" | jq -e '.rate_limits.five_hour.used_percentage' >/dev/null 2>&1; then
    echo "$input" | jq -c '{ts: (now|floor), rate_limits}' > "$HOME/.claude/usage-cache.json.tmp" \
        && mv "$HOME/.claude/usage-cache.json.tmp" "$HOME/.claude/usage-cache.json"
fi

MODEL=$(echo "$input" | jq -r '.model.display_name')
VERSION=$(echo "$input" | jq -r '.version // ""')
DIR=$(echo "$input" | jq -r '.workspace.current_dir')
COST=$(echo "$input" | jq -r '.cost.total_cost_usd // 0')
PCT=$(echo "$input" | jq -r '.context_window.used_percentage // 0' | cut -d. -f1)

CYAN='\033[36m'; GREEN='\033[32m'; YELLOW='\033[33m'; RED='\033[31m'; DIM='\033[2m'; RESET='\033[0m'

# Context bar color based on usage
if [ "$PCT" -ge 90 ]; then BAR_COLOR="$RED"
elif [ "$PCT" -ge 70 ]; then BAR_COLOR="$YELLOW"
else BAR_COLOR="$GREEN"; fi

FILLED=$((PCT / 10)); EMPTY=$((10 - FILLED))
[ "$FILLED" -gt 0 ] && printf -v FILL "%${FILLED}s" || FILL=""
[ "$EMPTY" -gt 0 ] && printf -v PAD "%${EMPTY}s" || PAD=""
BAR="${FILL// /█}${PAD// /░}"

BRANCH=""
git --no-optional-locks rev-parse --git-dir > /dev/null 2>&1 \
  && BRANCH=" | 🌿 $(git --no-optional-locks branch --show-current 2>/dev/null)"

# Line 1: model + version + dir + branch
VERSION_SUFFIX=""
[ -n "$VERSION" ] && VERSION_SUFFIX=" · v${VERSION}"
echo -e "${CYAN}[${MODEL}${VERSION_SUFFIX}]${RESET} 📁 ${DIR##*/}$BRANCH"

# Helper: format a future epoch as a human-readable countdown
reset_countdown() {
    local resets_at="$1" now="$2"
    local diff=$(( resets_at - now ))
    [ "$diff" -le 0 ] && return
    local h=$(( diff / 3600 )) m=$(( (diff % 3600) / 60 ))
    if [ "$h" -ge 24 ]; then
        local d=$(( h / 24 )) rh=$(( h % 24 ))
        echo " (resets in ${d}d ${rh}h)"
    else
        echo " (resets in ${h}h ${m}m)"
    fi
}

# Helper: build a colored 10-char bar for a percentage
rate_bar() {
    local pct="$1"
    local filled=$(( pct / 10 )) empty=$(( 10 - pct / 10 ))
    local fill="" pad=""
    [ "$filled" -gt 0 ] && printf -v fill "%${filled}s"
    [ "$empty"  -gt 0 ] && printf -v pad  "%${empty}s"
    echo "${fill// /█}${pad// /░}"
}

# Line 2: context bar + cost + duration [+ 5h quota] [+ 7d quota]
COST_FMT=$(printf '$%.2f' "$COST")
LINE2="ctx: ${BAR_COLOR}${BAR}${RESET} ${PCT}% | ${YELLOW}${COST_FMT}${RESET}"

NOW=$(perl -e 'print time')

FIVE_PCT=$(echo "$input"  | jq -r '.rate_limits.five_hour.used_percentage  // empty')
FIVE_RST=$(echo "$input"  | jq -r '.rate_limits.five_hour.resets_at         // empty')
WEEK_PCT=$(echo "$input"  | jq -r '.rate_limits.seven_day.used_percentage   // empty')
WEEK_RST=$(echo "$input"  | jq -r '.rate_limits.seven_day.resets_at         // empty')

echo -e "$LINE2"

if [ -n "$FIVE_PCT" ]; then
    FIVE_INT=$(printf '%.0f' "$FIVE_PCT")
    if [ "$FIVE_INT" -ge 90 ]; then FC="$RED"; elif [ "$FIVE_INT" -ge 70 ]; then FC="$YELLOW"; else FC="$GREEN"; fi
    FBAR=$(rate_bar "$FIVE_INT")
    FRST=""
    [ -n "$FIVE_RST" ] && FRST=$(reset_countdown "$FIVE_RST" "$NOW")
    echo -e "5h: ${FC}${FBAR}${RESET} ${FIVE_INT}%${DIM}${FRST}${RESET}"
fi

if [ -n "$WEEK_PCT" ]; then
    WEEK_INT=$(printf '%.0f' "$WEEK_PCT")
    if [ "$WEEK_INT" -ge 90 ]; then WC="$RED"; elif [ "$WEEK_INT" -ge 70 ]; then WC="$YELLOW"; else WC="$GREEN"; fi
    WBAR=$(rate_bar "$WEEK_INT")
    WRST=""
    [ -n "$WEEK_RST" ] && WRST=$(reset_countdown "$WEEK_RST" "$NOW")
    echo -e "7d: ${WC}${WBAR}${RESET} ${WEEK_INT}%${DIM}${WRST}${RESET}"
fi

# GitHub link row (only when remote is github.com)
REMOTE=$(git --no-optional-locks remote get-url origin 2>/dev/null)
if echo "$REMOTE" | grep -q "github.com"; then
    REMOTE=$(echo "$REMOTE" \
        | sed 's|git@github.com:|https://github.com/|' \
        | sed 's|\.git$||')
    REPO=$(echo "$REMOTE" | sed 's|https://github.com/||')
    echo -e "${DIM}🔗 ${REMOTE}${RESET}"
fi
