---
name: overnight
description: Kick off an unattended overnight implementation run with rate-limit protection. Use when the user invokes /overnight <task>, or says "run this overnight" / "work on this while I sleep". Pre-flights weekly quota, arms the stall watcher, then executes the task autonomously; the limit-guard hook handles 5h parking automatically.
---

# Overnight Run Kickoff

Arms the overnight protection stack, then executes the given task
autonomously until done. The user is leaving — after kickoff, assume nobody
answers questions until morning.

## Steps

1. **Pre-flight quota check** — read `~/.claude/usage-cache.json`:
   - 7d > 60%: warn in chat: "7d at <X>% — this run may not fit in the
     remaining weekly quota. Proceed?" The user is still present at kickoff —
     WAIT for the answer. This is the only permitted question.
   - 5h ≥ 85% already: recommend waiting for the 5h reset (state the time)
     before starting; ask proceed/wait.
   - Cache missing/stale (>10 min): note it, proceed anyway (statusline will
     refresh it as soon as work starts).
2. **Arm the stall watcher** — session-scoped, single Bash call:
   ```
   ~/.claude/scripts/arm-overnight.sh
   ```
   Writes the 3-line armed file (epoch / lead pid / run cwd) that lets the
   watcher's hard-death branch revive a crashed lead instead of only
   alerting, and clears this session's stale alert/revive flags.
3. **Restate the task** in 3-6 bullets (goal, definition of done, planned
   approach). Then execute autonomously:
   - No questions mid-run. Make reasonable calls; log each judgment call in a
     running "morning review" list to include in the final summary.
   - Verify as you go (build/test) — morning-you reviewing a broken tree is
     the failure mode.
   - **Hard gate: do not mark any item done until it's verified**, not just
     implemented. "Verified" = tests pass (parity tests too, if JS/Python both
     exist) AND, where the change has a runtime surface, behavior is actually
     exercised (Playwright, hardware write, on-device run) — not just
     typecheck/build green. If a spec item can't be verified this way
     (blocked, no test surface), say so explicitly in the morning summary
     instead of marking it done.
   - **Open the run ledger before the first delegated dispatch** —
     `docs/overnight-gates/ledger.md`, schema in
     `~/.claude/skills/overnight/gates.md`. Baseline commit at kickoff, one row
     per atomic step, append-only attempt log. Reconcile it against `git
     status` and `git log` after any park, compaction, or restart *before*
     dispatching anything — a stale VERIFIED row ships broken work, which is
     worse than a stale PENDING that merely gets redone.
   - **Every implementation dispatch declares its WRITE SET** — the exact files
     that agent may touch — and the ticket says so. Overlapping write sets
     (including manifests, lockfiles, and generated project files) never run in
     parallel: serialize, or give each a worktree. This is the preventive form
     of non-negotiable 2 below.
   - **Dispatch subagents with an explicit `model` param, always** — see
     `~/.claude/skills/overnight/gates.md` for the routing table. Never omit
     `model` on a subagent call: omitting it inherits *this session's* model,
     and if this run was kicked off as opus/fable (common for lead
     coordination quality on long unattended runs), every grep/locate/gate
     call would silently inherit that premium tier too. Route by task —
     haiku for locate/grep, sonnet for implementation and gates, opus/fable
     reserved for subtasks that genuinely need lead-tier reasoning — not by
     what the lead happens to be running as.
   - **Run quality gates at each atomic-step checkpoint**, not on every single
     edit and not skipped entirely — see `~/.claude/skills/overnight/gates.md`
     for the trigger rules (which gate fires on which kind of diff) and how to
     dispatch them (plain parallel `Agent` calls, never the `Workflow` tool —
     see gates.md for why). Gate findings get fixed inline before the step is
     marked done; that's part of "verified," not a separate pass.
   - **One of those gates asks a different question than the rest.** The
     best-practices, security, and a11y gates grade the *diff*; all three pass
     a clean, well-written implementation of the wrong thing. The
     task-conformance gate (`task-conformance-verifier`, `model: "sonnet"`) is
     handed the **original task text verbatim** — never your restatement, never
     the worker's account — and grades the result against what was actually
     asked. Its `Not checked` list is unverified territory: an item resting on
     one of those lines does not get marked done.
4. **Parking is not your job** — the limit-guard hook injects LIMIT GUARD
   messages; when one appears, follow ~/.claude/skills/overnight-park/SKILL.md.
   Never park preemptively without an injection.
5. **On completion**:
   - **Sweep for orphaned subagents FIRST**: `~/.claude/scripts/orphan-agents.sh 15`,
     and `TaskStop` each one it names. A named subagent that delivered its result
     by SendMessage does not exit — it parks awaiting a reply, and the task panel
     keeps counting wall-clock at it. On 2026-08-06 six sat that way for over four
     hours. Do this BEFORE writing the summary, because orphans and lost verdicts
     have the same cause: any row still reading "in flight" against a gate that
     actually finished is unverified, not verified. See `gates.md`.
   - iMessage: `~/.claude/scripts/imessage-self.sh "✅ Overnight task done: <one-line summary>"`
   - Disarm (session-scoped): `SID="${CLAUDE_CODE_SESSION_ID:-main}"; rm -f ~/.claude/overnight-armed-"$SID" ~/.claude/.stall-alerted-"$SID" ~/.claude/.revive-attempted-"$SID"`
   - Write the morning summary in chat, built from the ledger's final state:
     what was done, judgment calls made, gate findings (fixed and any
     explicitly skipped-with-reason), every escalation taken, every
     task-conformance `Not checked` item still outstanding, and anything
     needing review. Then write the session log per house rules.
6. **If genuinely blocked** (missing info only the user has, unrecoverable
   error): iMessage `⚠️ Overnight run blocked: <why>`, disarm as in step 5,
   write a summary of progress + the blocker, stop. Do not spin retrying the
   same failure all night.

## Non-negotiables

Each of these cost real time in the Rhapsode V2 M2 run (2026-07-30): roughly
**1h45m of wall clock lost to orchestration, none of it to the code.** They are
listed as rules rather than advice because "be more careful" demonstrably did
not work — the issue-closing failure below was diagnosed, written up in memory,
and then reproduced by the same session hours later.

1. **Background work and its wake mechanism ship in the SAME message.**
   `nohup … &` followed by "I'll poll" is not a plan; nothing re-invokes you.
   Three ~25-minute stalls came from exactly this, each surfacing to the user
   as a stall-watcher text rather than a result. Arm a `Monitor` (or a
   `run_in_background` waiter that EXITS on completion) in the same response
   that starts the work. Filter on failure signatures too, not just success —
   a success-only filter is silent through a crash, and silence looks identical
   to "still running."

2. **Gate a static tree.** `xcodegen generate` is step 1, so anything edited
   after it was never built. Confirm no agent is mid-edit and `git status` is
   stable before starting, and do not edit while a gate runs. A run that
   reported ALL GREEN having never built a new test file had to be discarded.
   Declared write sets (step 3) are the preventive half of this rule; this
   check is the detective half — keep both, they fail differently.

3. **Never run two gates at once**, and never gate-chain with a `pgrep` guard —
   a wrapper whose own argv contains the script name matches *itself*, waits
   forever, then releases into a run already in flight. `verify.sh` now takes a
   real lock and exits 3 rather than racing; do not defeat it.

4. **A GREEN verdict is not evidence that a test ran.** Confirm new tests
   executed BY NAME (`gate-metrics.csv`, or `xcrun xcresulttool get test-results
   tests`). A full gate with `ABS_FIXTURE_URL` unset skips both UI smokes;
   `verify.sh` now says PARTIAL GREEN, but check the tier you actually ran.

5. **Close issues at each milestone commit, not in an end-of-run sweep.**
   `git log -1 --pretty=%B <sha> | grep -oE "Refs #.*"`, then
   `gh issue comment N --body-file <f>` and `gh issue close N` (`--comment` gets
   blocked; the house rule forbids `--body`). Leave open anything with residual
   scope or a pending product decision, and say why in the comment — "closed"
   should mean "nothing left here," not "I committed something."

6. **Corroborate a LIMIT GUARD before acting on it.** The hook faithfully
   reports `~/.claude/usage-cache.json`, but the cache itself can be wrong — one
   injection claimed 88% weekly against an actual 1%, and acting on it produced
   a spurious park and a false iMessage to the user. Read the cache, sanity-check
   5h against 7d for coherence, and never send a user-visible message on a single
   unverified reading.

7. **Verify a claim before asserting it.** Two false accusations against the
   tooling in one run traced to a case-sensitive grep and a CSV query that
   filtered to attempt 1 only. When agents contradict a brief, they have been
   right every time so far — the code is the reliable source, the brief is not.
