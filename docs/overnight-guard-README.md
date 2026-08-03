# Overnight Limit Guard

Unattended long runs park before the 5h subscription cap, heartbeat through
the wait to keep the lead session's prompt cache warm, and resume on a fresh
window without re-ingesting a cold transcript. Quality gates (security/a11y/
best-practices) fire selectively during the run, routed to the cheapest model
that can do the job — independent of what the lead itself runs as. Built
2026-07-14, reworked 2026-07-20 (v2).

## Architecture

```
statusline-command.sh --(tees rate_limits)--> ~/.claude/usage-cache.json
                                                       |
PostToolUse hook (limit-guard.sh, throttled 5 min, per-session) ---+ reads
  5h >= 85%  -> inject park directive                              |
  7d >= 75%  -> inject weekly-stop directive                       |
                                                       v
overnight-park skill: TaskStop all subagents -> announce ->
  park-state-<sid>.json -> alert -> background park-sleeper.sh,
  <=55min heartbeat ticks (keeps lead cache warm) -> relaunch loop ->
  "WINDOW RESET" -> resume with FRESH subagents briefed from
  docs/overnight-gates/ reports, never cold-resumed old ones

/overnight kickoff skill: 7d pre-flight -> arm stall watcher (per-session) ->
  run task, dispatching quality gates per ~/.claude/skills/overnight/gates.md
  (trigger rules + explicit-model routing), plain parallel Agent calls, no
  Workflow tool
stall-watcher.sh (LaunchAgent, 5 min): loops all armed sessions independently,
  each: quiet 25 min + not parked ->
    lead pid dead (v3) -> clear stale park-state, snooze guard 15 min,
      `claude -p --resume <sid>` with reconcile-ledger prompt, alert 🩹
      (ONE revive per armed run; flag cleared only by disarm)
    lead pid alive or unknown -> alert ⚠️ (as before)
```

## Files

| File | Role |
|---|---|
| `~/.claude/hooks/limit-guard.sh` | PostToolUse hook (matcher `*`), thresholds 85%(5h)/75%(7d), per-session state |
| `~/.claude/scripts/park-sleeper.sh` | <=55min heartbeat ticks to reset; relaunched by the skill each tick; sleeps under `caffeinate -is` so a parked idle MacBook can't sleep through its own heartbeats |
| `~/.claude/scripts/stall-watcher.sh` | per-session armed-run stall detection + hard-death revive (v3) |
| `~/.claude/scripts/arm-overnight.sh` | kickoff step 2: writes 3-line armed file (epoch/lead pid/cwd), clears stale flags |
| `~/.claude/scripts/imessage-self.sh` | alert: iMessage -> fallback local notification + `~/.claude/alerts.log` |
| `~/.claude/skills/overnight/SKILL.md` | `/overnight <task>` kickoff |
| `~/.claude/skills/overnight/gates.md` | quality-gate trigger rules, explicit-model routing, dispatch, report/dedup convention |
| `~/.claude/skills/overnight-park/SKILL.md` | park / weekly-stop protocol |
| `~/Library/LaunchAgents/com.drewmerc.claude-stall-watcher.plist` | watcher schedule (300s) |
| statusline patch (top of `statusline-command.sh`) | sensor tee |

## State files (all `~/.claude/`, `<sid>` = `$CLAUDE_CODE_SESSION_ID` or `main`)

- `usage-cache.json` -- `{ts, rate_limits}` snapshot from statusline (global)
- `park-state-<sid>.json` -- present while that session is parked; watcher suppression + hook mutex
- `overnight-armed-<sid>` -- that session's stall watcher active while present; 3 lines since v3: epoch / lead claude pid / run cwd (1-line legacy files degrade to alert-only)
- `.revive-attempted-<sid>` -- hard-death revive already fired for this run; cleared only by arm/disarm, never by activity (prevents crash-revive ping-pong)
- `revive-<sid>.log` -- stdout/stderr of the revived non-interactive session
- `.limit-guard-last-check-<sid>` -- per-session throttle
- `.limit-guard-snooze` -- global; a resume/veto snooze covers the whole machine's stale-cache window
- `.stall-alerted-<sid>` -- per-session alert dedupe
- `alerts.log` -- every alert + errors (global)

Per-repo (not `~/.claude/`): `docs/overnight-gates/<gate>-<atomic-step-slug>.md`
-- gate findings, also the dedup check on resume.

## Policies

park 85% (5h) - stop 75% (7d) - pre-flight warn 65% (7d) - no auto-commit -
silent resume - completion alert - stall = 25 min quiet while armed -
never park on cache older than 10 min - park heartbeat every <=55min (inside
1h cache TTL) - hard TaskStop of all subagents (incl. gate agents) before
park - resume always spawns fresh subagents, never cold-resumes stopped ones
- gates fire by diff-content trigger, not on every checkpoint - gate model is
always explicit per `gates.md`'s table, never inherited from the lead
(matters most when the lead itself runs as opus/fable for coordination
quality -- subagents don't inherit that tier).

## Known state / TODO

- iMessage verified working 2026-07-15 (Automation permission granted;
  earlier -1712 timeouts were the ungranted consent). Fallback chain stays.
- Run `/fewer-permission-prompts` in each project before its first overnight
  run (permission prompts stall unattended sessions; watcher only alerts).
- v2 (2026-07-20) shipped: per-session park-state/armed/alert files, park
  heartbeat chain (was a single multi-hour sleep -- cache went cold on any
  park >1h and cost a full re-ingest at resume), quality-gate system
  (gates.md, explicit-model routing so an opus/fable lead doesn't push cheap
  subagent work to premium tier), 7d threshold aligned to 85%
  (later dropped to 75%, 2026-07-21 — 85% stop left only 15% weekly
  runway for the rest of the week's regular daily use).
- No a11y agent exists as a packaged skill/subagent yet -- `gates.md`
  documents the pattern to build inline (static tool first, LLM for the
  semantic gap) each time the a11y trigger fires. Worth promoting to a real
  skill once it's proven out across a few runs.
- v3 (2026-08-03, gnhf-inspired — github.com/kunchenguid/gnhf reviewed, not
  adopted; three ideas hand-ported): (1) park-sleeper sleeps under
  `caffeinate -is` — Claude Code's own 5-min power assertions lapse when a
  parked lead goes quiet, and an idle MacBook Air sleeping mid-park freezes
  the heartbeat timers; (2) gates.md gained a roll-back-before-retry ledger
  rule (restore the step's write set to HEAD before attempt N+1); (3)
  hard-death watchdog SHIPPED — closes the former backlog item. Revive
  requires: quiet 25 min + armed-file pid dead (or recycled to a non-claude
  comm) + sid != main + recorded cwd exists + no prior revive this run.
  Unit-tested against fake HOME (revive fires once, correct resume command,
  stale park-state cleared, snooze written, second pass alert-only) and
  arm/disarm round-tripped live; first real crash is the live validation —
  check `revive-<sid>.log` that morning.

## Verified 2026-07-14

sensor tee OK - hook 5 scenarios (silence/park/weekly/stale/parked) OK -
background sleeper wake re-invokes session OK - alert fallback chain OK -
LaunchAgent loaded OK

v2 (2026-07-20) changes are design-reviewed but not yet live-tested against a
real multi-hour park -- first overnight run after this change should be
treated as the verification run; watch that the heartbeat ticks actually
land ~55min apart, that resume doesn't show a cold-cache cost spike, and that
subagent dispatch actually carries an explicit model (spot-check one Agent
call in the transcript) when the lead is running as opus/fable.

## Uninstall

```
launchctl bootout gui/$(id -u)/com.drewmerc.claude-stall-watcher
rm ~/Library/LaunchAgents/com.drewmerc.claude-stall-watcher.plist
rm -rf ~/.claude/skills/overnight ~/.claude/skills/overnight-park
rm ~/.claude/hooks/limit-guard.sh ~/.claude/scripts/{park-sleeper,stall-watcher,imessage-self,arm-overnight}.sh
rm ~/.claude/park-state-*.json ~/.claude/overnight-armed-* ~/.claude/.stall-alerted-* ~/.claude/.limit-guard-last-check-* ~/.claude/.revive-attempted-* ~/.claude/revive-*.log
# remove the limit-guard PostToolUse entry from settings.json
# remove the usage-cache tee block from statusline-command.sh
```
