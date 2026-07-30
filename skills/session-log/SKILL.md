---
name: session-log
description: Save an Obsidian session log at conversation end. Use at end of every session — automatically, without being asked.
---

# Session Log

Writes a structured session log into an Obsidian vault so work survives the
context window. Paired with a `Stop` hook that refuses to end a substantive
session until the log exists.

## Configure the vault path

Set `CLAUDE_VAULT` in your shell profile:

```bash
export CLAUDE_VAULT="$HOME/path/to/YourVault"
```

Logs go to `$CLAUDE_VAULT/Sessions/YYYY-MM-DD-<project>-<topic>.md`.
Topic notes live in `$CLAUDE_VAULT/Topics/`.

If `CLAUDE_VAULT` is unset, ask once where the vault lives, then suggest the export.

## Rules

Never ask permission. Never skip. Write interim logs (`…-interim-<N>.md`) if
context exceeds 50% — a session that dies at 100% with no log loses everything.

## Template

```markdown
---
date: YYYY-MM-DD
project: <project>
tags: [session-log, <project>]
---
# Session: <Topic> (<Date>)
## Summary
## Key Decisions
## Changes Made
## Topics Referenced
- [[WikiLinks]]
## Open Items
## Next Steps
## See Also
- [[relevant notes]]
```

- **See Also**: WikiLinks to related topics only — never modify note content inline.
- Update topic notes by appending a session link to their Related Notes section.

## Topic notes (after saving the log)

Check whether any proper noun (person, project, tool, org) appears in 3+ recent
sessions without a topic note in `$CLAUDE_VAULT/Topics/`. If so, suggest creating
one. If approved:

1. Create lockfile: `$CLAUDE_VAULT/.topic-linker.lock`
2. Create the topic note
3. Re-scan all files, add WikiLinks to See Also footers
4. Remove lockfile
5. Report: "Created [N] notes, updated [M] footers."

The lockfile exists because step 3 rewrites footers across the whole vault; two
concurrent sessions doing that at once interleave writes and corrupt them.
