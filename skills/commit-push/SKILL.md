---
name: commit-push
description: Commit staged (or all) changes and push to the current remote branch. Use when the user says /commit-push, wants to commit and push without opening a PR, says "push this up", "commit and push", or "ship this". Do NOT use when the user wants to open a pull request — that's /commit-push-pr.
---

# Commit and Push

Commit the current changes and push to origin. No PR creation.

## Steps

1. Run `git status` and `git diff --cached` to see what's staged. If nothing is staged, stage all tracked changes with `git add -u`.
2. Show the user what will be committed and confirm the scope looks right.
3. Write the commit message to a **session-unique** path using the Write tool — never heredocs or `-m`, since the Bash tool injects ANSI codes that end up verbatim in the commit. Use the session scratchpad dir if one exists, otherwise `/tmp/msg-<repo>-<short-sha-or-timestamp>.txt`. Never a shared path like `/tmp/msg.txt`: concurrent Claude sessions clobber it mid-commit and you commit the other session's message.
4. Run `git commit -F <that path>`.
5. Run `git push`. If the branch has no upstream, run `git push -u origin HEAD`.
6. Report the pushed commit hash and branch.

## Commit message format

- One-line summary (imperative mood, ≤72 chars)
- Blank line, then body if needed
- Focus on *why*, not *what* — the diff shows the what
- Match the repo's existing commit style (check `git log --oneline -5`)

## What not to do

- Do not open a PR or suggest one unprompted
- Do not amend previous commits
- Do not force push
- Do not skip the staged-file verification step — missing files before push has been a recurring issue
