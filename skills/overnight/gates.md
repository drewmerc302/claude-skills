# Overnight Quality Gates

Reference for `/overnight` step 3. Defines which subagent runs on which kind
of diff, what model each subagent call should use, and how findings get
recorded so a park/resume cycle doesn't re-run work it already did.

Not every checkpoint needs every gate. Running all four on every commit is
expensive and mostly redundant — a one-line copy change doesn't need a
security review. Route by what the diff actually touches.

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
- **Security** — fires when diff touches: auth/session handling, crypto,
  network or file I/O boundaries, shell/SQL/command string construction,
  secrets or env var handling, (de)serialization, or adds a new dependency.
- **A11y** — fires when diff touches UI-surface files: `.jsx/.tsx/.html/.css`
  (or framework equivalents — SwiftUI `View`, Jetpack Compose), specifically
  interactive elements, forms, images, or color/contrast changes.

If none of security/a11y trigger, only the best-practices gate runs. Log
which gates fired and which didn't (one line each) in the morning summary —
silent skipping reads as "reviewed" when it wasn't.

## Dispatch

Fire triggered gates as parallel `Agent` tool calls (multiple tool_use blocks
in one message) — **not** the `Workflow` tool. [Past incident: a `Workflow`
dispatch burned 2.7M tokens / 75% of a weekly quota on a routine comparison
task — wrong tool for this scale of work, and it requires its own explicit
opt-in the user hasn't given for unattended runs.] Plain `Agent` calls in
parallel are enough; the gates are independent of each other.

### Best-practices / conciseness

Use `Agent` with a reviewer subagent whose output is severity-tagged and
one-line-per-finding — feed findings straight into the fix loop, don't
re-summarize them first.

> Locally this routes to `subagent_type: "caveman:cavecrew-reviewer"` (from the
> third-party `caveman` plugin, not vendored here). Any terse diff-reviewer
> works; `subagent_type: "feature-dev:code-reviewer"` is a reasonable stock
> substitute. Verbose reviewers defeat the purpose — the gate runs at every
> atomic step, so its output cost compounds across a whole unattended run.

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

## Report files and dedup

Each gate that fires writes a short report to
`docs/overnight-gates/<gate>-<atomic-step-slug>.md` in the repo being worked
on (create the dir if missing). Keep it compressed — findings list plus
fixed/skipped status, not prose. This is what makes resume-after-park cheap:
a fresh subagent gets briefed from this file instead of re-reading the full
diff and re-deriving findings.

Before dispatching a gate, check whether a report already exists for this
exact atomic step (same slug). If it does and nothing has changed in that
step's files since, skip the gate and note "already covered, see
docs/overnight-gates/..." instead of re-running it. This matters most right
after a park/resume, where it's tempting to re-verify everything from
scratch — don't; that's exactly the re-ingest cost the heartbeat/fresh-agent
design in `overnight-park/SKILL.md` is trying to avoid.
