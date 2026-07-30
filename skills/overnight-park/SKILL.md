---
name: overnight-park
description: Park protocol for the limit-guard hook. Use ONLY when a "LIMIT GUARD" message appears in context (injected by the PostToolUse limit-guard hook) — either mode park (5h cap near) or mode weekly-stop (7d cap binding). Never invoke this proactively without a LIMIT GUARD injection.
---

# Overnight Park

Executes the park/stop protocol when the limit-guard hook signals a near-limit
condition. The hook injection supplies: mode (`park` or `weekly-stop`), pct,
and reset_epoch.

## Mode: park (5h cap near)

Execute these steps immediately. Do NOT start any new work first. Do NOT
wait for a user reply at any step.

1. **Stop every active subagent first** — this includes quality-gate agents
   (security/a11y/best-practices reviewers), not just implementation agents.
   `TaskStop` every Task-tool background agent that hasn't already returned.
   Do this *before* announcing or writing park-state. This is the
   2026-07-16 hard-park directive: a soft park that lets agents run to a
   "natural stopping point" is what burned a full month's overage budget
   comparing guitars. A half-written file is recoverable from the
   transcript; burned overage credits are not.
2. **Announce** (one line in chat): `⏸ 5h limit at <pct>% — parking until
   <HH:MM local, from reset_epoch>. Say "resume now" to override.`
3. **Write session-scoped park-state** — single Bash call, no heredoc.
   Filename is per-session (`$CLAUDE_CODE_SESSION_ID`, falls back to `main`
   if unset) so two overnight sessions in different projects don't clobber
   each other's park-state:
   ```
   SID="${CLAUDE_CODE_SESSION_ID:-main}"
   jq -n --arg task "<one-line task summary>" --arg next "<one-line next step>" \
     --arg sid "$SID" \
     --argjson reset <reset_epoch> --argjson at "$(date +%s)" \
     '{mode:"park", session_id:$sid, task:$task, next_step:$next, reset_epoch:$reset, parked_at:$at}' \
     > ~/.claude/park-state-"$SID".json
   ```
4. **iMessage**: `~/.claude/scripts/imessage-self.sh "⏸ Claude parked at <pct>% (5h cap). Resumes ~<HH:MM>. Task: <task summary>"`
5. **Launch heartbeat sleeper** — Bash with `run_in_background: true`:
   `~/.claude/scripts/park-sleeper.sh <reset_epoch>`
   Unlike a single multi-hour sleep, this wakes in ≤55min ticks (inside the
   ~1h prompt-cache TTL) so the lead session's own context stays warm through
   the park instead of going cold and costing a full re-ingest at resume.
6. **End the turn** with one short line ("Parked. Resuming ~<HH:MM>."). No
   further tool calls.

**On each heartbeat wake** (completion message starts with "PARK
HEARTBEAT"): this is a deliberately cheap tick, not a resume. Immediately
relaunch `~/.claude/scripts/park-sleeper.sh <reset_epoch>` (same
run_in_background Bash call, same reset_epoch) and end the turn again. Do
nothing else — no status checks, no re-reading files, no usage re-verify.
The whole point is that this tick costs near-zero tokens; padding it with
extra work defeats the purpose. Repeat until a wake says "WINDOW RESET".

**On final wake** (completion message says "WINDOW RESET"): continue the
task exactly where the transcript left off. Do not re-plan, do not re-verify
usage (the snooze covers the stale-cache window). Any subagents stopped in
step 1 are abandoned, not resumed — see "Resume = FRESH agents" below.
Before re-dispatching a quality gate (security/a11y/best-practices) that had
already produced a report before the park, check
`docs/overnight-gates/<gate>-*.md` (see `~/.claude/skills/overnight/gates.md`)
for an existing report covering the same diff — skip re-running it if found.

**User veto** ("resume now" / "unpark" while parked):
1. Stop the sleeper background task (TaskStop / kill).
2. `echo <reset_epoch> > ~/.claude/.limit-guard-snooze` (silences the guard
   for the rest of this window — user accepted the risk).
3. `rm -f ~/.claude/park-state-"${CLAUDE_CODE_SESSION_ID:-main}".json`
4. Continue working.

## Mode: weekly-stop (7d cap binding)

Parking is pointless — a fresh 5h window draws from a dead weekly budget.

1. **Finish only the current atomic step** (complete the in-flight edit/test;
   start nothing new).
2. **Snooze the guard until the weekly reset**:
   `echo <reset_epoch> > ~/.claude/.limit-guard-snooze`
   (prevents the hook nagging every 5 min in any session; everything is
   equally capped until the weekly reset).
3. **Disarm the stall watcher** (session-scoped):
   `rm -f ~/.claude/overnight-armed-"${CLAUDE_CODE_SESSION_ID:-main}" ~/.claude/.stall-alerted-"${CLAUDE_CODE_SESSION_ID:-main}"`
4. **iMessage**: `~/.claude/scripts/imessage-self.sh "🛑 Claude stopped: 7d limit at <pct>%. Resets <day/time from reset_epoch>. Progress: <one line>"`
5. **End the turn** with a short summary in chat: what got done, exact next
   step for when quota returns. No park-state file, no sleeper.

## Notes

- **Resume = FRESH agents, never cold-resume killed ones (2026-07-16 cost
  lesson)**: a park usually outlives the prompt-cache TTL for *subagents*
  even with the heartbeat chain keeping the *lead* warm — subagents don't get
  heartbeat ticks of their own while stopped. SendMessage-resuming a
  big-context agent re-ingests its entire transcript at full price —
  resuming several 400k-context agents cold once cost ~30% of a 5h window.
  Treat stopped agents as ABANDONED: their reports already live in the
  lead's context and `docs/`. On resume, spawn fresh small-context agents
  briefed from those reports. Only cold-resume an old agent if its
  un-reported in-flight state is genuinely irreplaceable.
- Do not auto-commit anything in either mode — working tree + transcript are
  the state. Commits happen only when the user asks.
- If the user is present and objects before the sleeper launches, treat as
  veto (see above).
- Multi-session: park-state and stall-arm files are keyed by
  `$CLAUDE_CODE_SESSION_ID` (falls back to `main`) so concurrent overnight
  runs in different projects/terminals don't clobber each other's state. The
  limit-guard hook itself checks/creates per-session files the same way.
