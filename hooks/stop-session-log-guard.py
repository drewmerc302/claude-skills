#!/usr/bin/env python3
"""
Stop hook — enforce that a SUBSTANTIVE session produces a session log.

The Stop hook fires at the end of EVERY assistant turn, not at session end
(there is no reliable "session ending" event the model can act on). So this:

  1. Loop-guards on stop_hook_active (never re-block a continuation).
  2. Fires AT MOST ONCE per session (a marker file keyed by session_id),
     so a long session gets a single nudge, not per-turn spam.
  3. Only nudges when the session looks substantive AND no log exists yet.
  4. Blocks softly: the model can write the log OR say it'll log later and
     stop again (stop_hook_active=true -> no re-block). One bounded interruption.

Fails OPEN on any error (a buggy Stop hook must never wedge a session).

Tunables below: PROMPT_THRESHOLD / TOOLUSE_THRESHOLD.
"""

import sys
import json
import os

# Path to your Obsidian vault. Set CLAUDE_VAULT in your shell profile, or edit
# the fallback below. Must match the vault the session-log skill writes to.
VAULT = os.environ.get("CLAUDE_VAULT", os.path.expanduser("~/Vault"))
SESSIONS_MARKER = os.path.join(
    os.path.basename(VAULT), "Sessions", ""
)  # substring that marks a log-file write
MARKER_DIR = os.path.join(os.environ.get("TMPDIR", "/tmp"), "claude-stop-guard")

# A session counts as "substantive" if EITHER threshold is crossed.
PROMPT_THRESHOLD = 4  # genuine user prompts (excludes tool_result turns)
TOOLUSE_THRESHOLD = 8  # total tool calls


def scan(transcript_path):
    """Return (prompt_count, tooluse_count, log_written)."""
    prompts = 0
    tools = 0
    log_written = False
    with open(transcript_path, "r") as fh:
        for line in fh:
            line = line.strip()
            if not line:
                continue
            try:
                evt = json.loads(line)
            except json.JSONDecodeError:
                continue
            msg = evt.get("message") or {}
            role = msg.get("role") or evt.get("type")
            content = msg.get("content")
            if isinstance(content, str):
                content = [{"type": "text", "text": content}]
            if not isinstance(content, list):
                continue
            for block in content:
                if not isinstance(block, dict):
                    continue
                btype = block.get("type")
                if role == "user" and btype == "text":
                    prompts += 1
                elif btype == "tool_use":
                    tools += 1
                    name = block.get("name", "")
                    inp = block.get("input", {}) or {}
                    path = inp.get("file_path") or inp.get("path") or ""
                    is_session_path = SESSIONS_MARKER in path or (
                        "Sessions/" in path and "obsidian" in name
                    )
                    if is_session_path and path.endswith(".md"):
                        # written via Write/Edit or any obsidian *_note tool
                        if name in ("Write", "Edit") or "obsidian" in name:
                            log_written = True
    return prompts, tools, log_written


def main():
    raw = sys.stdin.read()
    try:
        data = json.loads(raw) if raw.strip() else {}
    except json.JSONDecodeError:
        data = {}

    # 1. Loop guard.
    if data.get("stop_hook_active"):
        sys.exit(0)

    transcript_path = data.get("transcript_path", "")
    session_id = data.get("session_id", "")
    if not transcript_path or not os.path.isfile(transcript_path):
        sys.exit(0)

    prompts, tools, log_written = scan(transcript_path)

    # 3a. Already logged -> nothing to do.
    if log_written:
        sys.exit(0)

    # 3b. Not substantive -> no nag (trivial Q&A doesn't earn a log).
    substantive = prompts >= PROMPT_THRESHOLD or tools >= TOOLUSE_THRESHOLD
    if not substantive:
        sys.exit(0)

    # 2. Once-per-session marker.
    marker = os.path.join(MARKER_DIR, f"{session_id or 'nosid'}.nagged")
    try:
        os.makedirs(MARKER_DIR, exist_ok=True)
        if os.path.exists(marker):
            sys.exit(0)  # already nudged this session
        open(marker, "w").close()
    except OSError:
        # If we can't write the marker we'd risk per-turn spam -> stay silent.
        sys.exit(0)

    reason = (
        f"This session looks substantive ({prompts} prompts, {tools} tool calls) "
        f"but no session log has been written to {VAULT}/Sessions/ yet. "
        "If the work is done, write one now (pattern: "
        "YYYY-MM-DD-<project>-<slug>.md). If you're mid-session, reply that "
        "you'll log at the end and stop — you won't be asked again this session."
    )
    print(json.dumps({"decision": "block", "reason": reason}))
    sys.exit(0)


if __name__ == "__main__":
    try:
        main()
    except Exception:
        sys.exit(0)
