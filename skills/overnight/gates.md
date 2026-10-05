# Overnight Quality Gates

Reference for `/overnight` step 3. Defines which subagent runs on which kind
of diff, what model each subagent call should use, and how findings get
recorded so a park/resume cycle doesn't re-run work it already did.

Not every checkpoint needs every gate. Running all four on every commit is
expensive and mostly redundant — a one-line copy change doesn't need a
security review. Route by what the diff actually touches.

## Contents

- Model routing
- Gate trigger rules
- Dispatch (best-practices, task conformance, security, a11y)
- Gates RETURN their verdict
- Report files and dedup
- Run ledger

## Model routing

**Every subagent `Agent` call in an overnight run passes an explicit `model`
param. Never omit it.** Omitting `model` inherits the *parent session's*
model — and overnight leads commonly run as `opus` or `fable` on purpose, for
coordination/judgment quality across a long unattended run. That's a lead
choice, not a signal to raise subagent tiers: an opus/fable lead that omits
`model` on every dispatch pushes cheap grep/locate work and routine gate
reviews to premium pricing for zero quality benefit — the exact "sub-agents
burning tokens unnecessarily" failure this table exists to prevent. Route by
task, independent of what the lead happens to be running as:

| Task | Model | Why |
|---|---|---|
| Locate/grep/"where is X defined" | `haiku` | pattern match, no reasoning depth needed |
| Main implementation | `sonnet` | standard coding tier regardless of lead's tier |
| Best-practices / conciseness gate | `sonnet`, via `cavecrew-reviewer` | already tuned for compressed output |
| Task-conformance gate | `sonnet`, via `task-conformance-verifier` | grading a diff against a stated spec is workhorse work; pin it explicitly — the agent must never inherit an opus/fable lead's tier, since it fires on most steps |
| A11y gate | `sonnet`, via `a11y-reviewer` | one agent call runs the static-tool pass (mechanical) and the semantic pass (judging label/focus/alt-text quality needs real reasoning) in sequence — not worth splitting into two dispatches |
| Security gate | `sonnet`; escalate to `opus` if the diff touches auth, crypto, or deserialization | subtle-vuln reasoning benefits from more headroom on the highest-stakes surfaces |
| Genuinely hard architectural/design subtask | `opus` or `fable`, explicit, only when the step's complexity actually warrants lead-tier reasoning | matches why the lead itself runs at that tier — reserve it, don't default to it |

If a task doesn't map cleanly to a row above, default to `sonnet` explicit —
never fall back to inherit-from-lead as the "safe" choice.

## Gate trigger rules

Evaluate against the diff at each atomic-step checkpoint (same "atomic step"
granularity already used by the weekly-stop protocol — not per-file-save,
not only-at-the-very-end).

- **Best-practices / conciseness** — always fires. Cheap enough (compressed
  `cavecrew-reviewer` output) that skipping it isn't worth the risk of a
  regression sitting in the tree till morning.
- **Task conformance** — fires on any atomic step that touched more than one
  file, or any step whose spec item has acceptance criteria. Skip only for
  single-file zero-logic diffs (formatting, comments, docs copy). This is the
  one gate that asks *"did this do what was asked"* rather than *"is this diff
  any good"* — the other three grade the code and would all pass a clean,
  well-written implementation of the wrong thing.
- **Security** — fires when diff touches: auth/session handling, crypto,
  network or file I/O boundaries, shell/SQL/command string construction,
  secrets or env var handling, (de)serialization, or adds a new dependency.
- **A11y** — fires when diff touches UI-surface files: `.jsx/.tsx/.html/.css`
  (or framework equivalents — SwiftUI `View`, Jetpack Compose), specifically
  interactive elements, forms, images, or color/contrast changes.

If none of security/a11y trigger, best-practices and (per its own rule above)
task-conformance run. Log which gates fired and which didn't (one line each)
in the morning summary — silent skipping reads as "reviewed" when it wasn't.

## Dispatch

Fire triggered gates as parallel `Agent` tool calls (multiple tool_use blocks
in one message) — **not** the `Workflow` tool. [Past incident: Workflow burned
2.7M tokens / 75% of a weekly quota comparing two guitars — wrong tool for
this scale of task, and it requires its own explicit opt-in the user hasn't
given for unattended runs.] Plain `Agent` calls in parallel are enough; the
gates are independent of each other.

### Best-practices / conciseness

Use `Agent` with `subagent_type: "caveman:cavecrew-reviewer"`. Point it at the
diff for the current atomic step. Its output is already severity-tagged,
one-line-per-finding, no praise — feed findings straight into the fix loop,
don't re-summarize them first.

### Task conformance

Use `Agent` with `subagent_type: "task-conformance-verifier"`, `model: "sonnet"`
(`~/.claude/agents/task-conformance-verifier.md`). Three rules make this gate
worth anything; violating any one of them turns it into an expensive rubber stamp:

1. **Hand it the ORIGINAL task text verbatim** — the spec item, issue body, or
   the exact wording from the kickoff restatement. Never your own summary of
   what the step was meant to do, and never the implementing agent's account of
   what it did. If you paraphrase, the verifier grades your paraphrase and the
   independence is gone.
2. **Gate a static, committed tree.** Same rule as non-negotiable #2: no agent
   mid-edit, `git status` stable. After the verifier returns, `git status` must
   still be clean and `HEAD` unchanged — any mutation during the run voids the
   verdict, re-run it.
3. **Grade the diff, not the narrative.** Its `Not checked` section is load-
   bearing output, not boilerplate — carry it into the morning summary verbatim.
   Items listed there are unverified, and a spec item resting on one of them
   cannot be marked done.

If the project ships a locking verify script (Rhapsode's `verify.sh` exits 3
rather than racing), the verifier runs *that* script — do not fire it in
parallel with another gate that also invokes it, and do not defeat the lock.

`FAIL` or `PASS_WITH_NOTES` findings go into the fix loop like any other gate's;
re-verify after the fix rather than assuming the fix landed.

### Security

Invoke the `security-review` skill (or `Agent` with a security-focused prompt
if that skill's scope doesn't fit the diff) against the current atomic step's
diff. First time this fires in a session, sanity-check its output actually
addresses the trigger reason (e.g. an auth-diff review should mention the
auth path) — don't assume unverified scope on a run nobody's watching.

### A11y

Use `Agent` with `subagent_type: "a11y-reviewer"` (`~/.claude/agents/a11y-reviewer.md`), scoped
to the current atomic step's diff. It handles the full procedure itself: checks for existing
static tooling (`eslint-plugin-jsx-a11y`, `axe-core`, an XCTest accessibility audit, Compose a11y
checks) and runs it when present, then a semantic pass for what static tools miss (label quality,
focus order intent, alt-text quality), and explicitly flags in its own output when no static
tooling exists and the check ran LLM-only. Feed its findings straight into the fix loop, same as
the best-practices gate.

## Gates RETURN their verdict. They never message it, and they are never named.

Spawn every gate WITHOUT a `name`, and have it deliver findings as its final
text (or a `schema` object). Do not tell a gate to "report to the team lead."

Both halves of that matter, and violating it cost a full run on 2026-08-06:

* **A named subagent is an addressable teammate.** It sends its report via
  SendMessage, ends its turn, and then *parks awaiting a reply that never
  comes*. It does not exit. Five finished gates sat at `in_process_teammate`
  for 4h15m while the task panel counted wall-clock at them, which reads
  exactly like work in progress. An unnamed subagent terminates when it
  returns, and cannot leak this way.
* **A message is not an artifact.** Findings delivered into the lead's context
  live only in that context — and the next compaction throws them away. That
  run lost four gate verdicts to compaction and carried six ledger rows still
  reading "gates in flight" hours after every gate had finished. The findings
  happened to be already-fixed. That was luck, not a process.

**Consume, then stop.** The moment a gate's verdict is read and its ledger row
updated, `TaskStop` it. Do not leave it parked "in case there's a follow-up" —
dispatch a fresh one, which is cheap; an orphan is not.

**Sweep before the morning summary**, and after any park or compaction:

```
~/.claude/scripts/orphan-agents.sh 15
```

It flags subagents whose transcript has been idle N minutes while the panel
still shows them running. Transcript mtime is the evidence; the panel's timer
is time-since-spawn and proves nothing. A run that ends with orphans on the
panel has almost certainly also lost verdicts — check the ledger for rows still
saying "in flight" before trusting any of them.

## Report files and dedup

Each gate that fires writes a short report to
`docs/overnight-gates/<gate>-<atomic-step-slug>.md` in the repo being worked
on (create the dir if missing). Keep it compressed — findings list plus
fixed/skipped status, not prose.

**This file is the deliverable** — the gate writes it and then returns the path
plus a one-line verdict. A gate that returned findings but wrote no file has not
run to completion; on 2026-08-06 four gates reported and `docs/overnight-gates/`
contained nothing but ledgers.

Writing the file is also what makes resume-after-park cheap:
a fresh subagent gets briefed from this file instead of re-reading the full
diff and re-deriving findings.

Before dispatching a gate, check whether a report already exists for this
exact atomic step (same slug). If it does and nothing has changed in that
step's files since, skip the gate and note "already covered, see
docs/overnight-gates/..." instead of re-running it. This matters most right
after a park/resume, where it's tempting to re-verify everything from
scratch — don't; that's exactly the re-ingest cost the heartbeat/fresh-agent
design in `overnight-park/SKILL.md` is trying to avoid.

## Run ledger

Gate reports dedup *findings*. They do not record *run state* — which step is
in flight, which agent owns which files, how many times a failing step has been
retried. Across a 5h park/resume that state lives only in a context window that
is about to be thrown away, and a resumed lead reconstructs it by guessing.
The ledger is the fix.

**Write `docs/overnight-gates/ledger.md` before the first delegated dispatch of
the run** — including single-worker runs — and append to it as the run
progresses. Never rewrite past rows; the history is the point.

```markdown
# Overnight ledger — <task slug>
baseline: <commit sha> on <branch>   # `git rev-parse HEAD` at kickoff, before any edit
armed:    <ISO timestamp>

## Steps
| # | atomic step | write set | status | attempts | gates | evidence |
|---|---|---|---|---|---|---|
| 1 | parse GP5 header | src/gp5/header.rs, tests/header.rs | VERIFIED | 1 | bp✓ tc✓ | 3d1f9ac, 14 tests |
| 2 | wire CLI flag | src/cli.rs | IN_FLIGHT | 2 | — | — |

## Attempts (append-only)
- step 2 attempt 1 — sonnet worker — FAILED: clap version mismatch, see gate report
- step 2 attempt 2 — sonnet worker — IN_FLIGHT since 02:14
```

Statuses: `PENDING` → `IN_FLIGHT` → `IMPLEMENTED` → `VERIFIED` | `BLOCKED`.
`IMPLEMENTED` is not `VERIFIED` — the SKILL.md hard gate lives in this column,
so nothing reaches `VERIFIED` without gate evidence in the evidence cell.

Three rules:

- **Write sets are declared, not discovered.** Every implementation dispatch
  names the files that agent may touch, and the ticket says so explicitly. Two
  dispatches whose write sets overlap — including manifests, lockfiles, and
  generated project files — do not run in parallel: serialize them, or give
  each a git worktree. This is the preventive form of non-negotiable #2, which
  currently only catches the collision after a run has to be discarded.
- **Bound the retries.** Two failed attempts at a step by the same tier, then
  either escalate one tier (with the escalation journaled as its own attempt
  row) or take it over as the lead. Never a third identical retry on unchanged
  input — that is the "spin retrying the same failure all night" failure mode
  with a counter attached.
- **Roll back before retrying.** A failed attempt's half-finished edits do not
  survive into the next attempt: before dispatching attempt N+1, restore the
  step's declared write set to HEAD (`git checkout HEAD -- <write-set files>`,
  plus delete untracked files the attempt created inside its write set) and
  journal the rollback in the attempt row. Scope the restore to the write set —
  a bare `git reset --hard` is only safe when no other step is IN_FLIGHT,
  because it would also destroy a parallel agent's uncommitted work. Attempt
  N+1 starts from the same tree attempt N did, or its failure teaches nothing.
- **Reconcile before dispatching anything after a park, compaction, or
  restart.** Read the ledger, then check it against `git status`, `git log
  --oneline <baseline>..HEAD`, and any still-running background jobs. A stale
  `IN_FLIGHT` whose agent died, or a stale `VERIFIED` whose commit isn't in the
  log, is more dangerous than a `PENDING` — `PENDING` gets redone, a false
  `VERIFIED` ships. Fix the rows to match reality *first*, then continue.

The ledger's final state is the skeleton of the morning summary — steps
verified, steps blocked and why, escalations taken, and every `Not checked`
item the task-conformance gate surfaced.
