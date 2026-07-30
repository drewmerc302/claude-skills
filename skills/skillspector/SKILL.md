---
name: skillspector
description: Scan an AI agent skill for security vulnerabilities and malicious patterns before installing or trusting it. Use when the user wants to vet, audit, or security-check a skill — triggers include "scan this skill", "is this skill safe", "check this skill for malware", "audit a skill before I install it", "vet this agent skill", or pointing at a SKILL.md / skill directory / skill repo URL and asking whether it's safe. Runs NVIDIA SkillSpector via a local Docker image. Do NOT use for scanning general application source code, container images, or dependencies — this is specifically for agent skills.
---

# SkillSpector — AI Skill Security Scanner

Wraps NVIDIA SkillSpector (`skillspector:latest` Docker image) to scan agent skills for vulnerabilities, malicious patterns, and CVEs. Two-stage: fast static pattern + YARA matching, then an LLM semantic pass that reduces false positives. **Default to LLM mode** — the static-only pass over-flags brutally (see Gotchas); the LLM pass returns reasoned findings.

## Configure

Set `SKILLSPECTOR_REPO` in your shell profile — the local clone of
[NVIDIA/skillspector](https://github.com/NVIDIA/skillspector):

```bash
export SKILLSPECTOR_REPO="$HOME/src/skillspector"
```

## Prerequisites (check first, fix if missing)

1. **Docker running** — `docker version --format '{{.Server.Version}}'`. If it fails, tell the user to start Docker Desktop.
2. **Image exists** — `docker image inspect skillspector:latest >/dev/null 2>&1`. If missing, build it:
   ```bash
   cd "$SKILLSPECTOR_REPO" && docker build -t skillspector .
   ```
   If that directory is gone, re-clone: `git clone https://github.com/NVIDIA/skillspector.git`.
3. **API key for the LLM pass** — a persistent, git-ignored env file holds the Anthropic credentials:
   ```
   "$SKILLSPECTOR_REPO"/.env   (SKILLSPECTOR_PROVIDER=anthropic + ANTHROPIC_API_KEY, chmod 600)
   ```
   Confirm it's usable, else fall back to `--no-llm`:
   ```bash
   ENVF="$SKILLSPECTOR_REPO"/.env
   test -s "$ENVF" && grep -q 'ANTHROPIC_API_KEY=sk-' "$ENVF" && echo "LLM ready" || echo "no key -> use --no-llm"
   ```
   If the file is gone, recreate it (have the user paste the key; never echo it into the chat/transcript).

## Running a scan

The image mounts the current directory as `/scan` and the entrypoint is `skillspector`. Target paths are relative to the mounted dir. `--env-file` supplies the provider + key, enabling the LLM pass. JSON output is easiest to triage programmatically.

**Local skill directory or SKILL.md (default, LLM mode)** — mount the parent dir, pass the relative path:
```bash
docker run --rm -v "$HOME/.claude/skills:/scan" \
  --env-file "$SKILLSPECTOR_REPO"/.env \
  skillspector scan ./SKILLNAME/ --format json
```
`$PARENT_DIR` is the parent of whatever you scan; for installed skills it's `$HOME/.claude/skills`.

**Remote skill repo (vet before install)** — no mount needed:
```bash
docker run --rm --env-file "$SKILLSPECTOR_REPO"/.env \
  skillspector scan https://github.com/user/some-skill --format json
```

**Zip archive:**
```bash
docker run --rm -v "$PARENT_DIR:/scan" \
  --env-file "$SKILLSPECTOR_REPO"/.env \
  skillspector scan ./some-skill.zip --format json
```

### Static-only fallback

Drop `--env-file` and add `--no-llm` when the `.env` is missing/empty **or** the LLM analyzer crashes on a skill (see Gotchas). Triage the static findings manually — they're noisy:
```bash
docker run --rm -v "$HOME/.claude/skills:/scan" skillspector scan ./SKILLNAME/ --no-llm
```

### Machine-readable output

When the user wants a saved report (mount a writable dir):
```bash
docker run --rm -v "$PARENT_DIR:/scan" skillspector scan ./SKILLNAME/ --format sarif --output report.sarif
# --format also accepts: json, markdown, text (default)
```

## Interpreting results

SkillSpector prints an overall **Severity** and **Recommendation** (SAFE / CAUTION / UNSAFE), then per-finding rows with severity, rule ID, location (`file:line`), and a confidence %.

- **Static-only mode is noisy.** Pattern/YARA rules flag legit skills — e.g. a doc that *mentions* `shell=True`, `rm -rf`, cron, or credential handling. Low-confidence (<60%) findings on documentation/reference files are usually false positives.
- **Weight by confidence + location.** A HIGH finding at 85%+ inside an executable script (`.sh`, `.py`) matters far more than the same rule firing in a markdown reference.
- **Real red flags:** info-stealer / credential-exfil patterns in executable code, network calls to unexpected hosts, obfuscated/encoded payloads, persistence mechanisms (cron, startup hooks) in code rather than prose.
- **Read the code before relaying any real-looking finding.** Both passes overstate. The LLM flags *data flows* ("untrusted transcript → shell-command generator") that sound like RCE but often don't execute — the output is captured and returned as text. Open the cited `file:line`, trace whether attacker-controlled input is actually executed vs just stored/returned, and report ground truth — not the scanner's severity verbatim.
- **Always report:** the overall recommendation, then a short triaged list — genuine concerns vs likely-false-positives, each verified against the code — and a clear verdict on whether it's safe to install. Don't just dump the raw table.

## Gotchas

- **LLM analyzer crashes on binary blobs.** A skill shipping compressed/binary data (e.g. `*.json.gz`) can make the LLM emit structured output that fails SkillSpector's pydantic schema: `Error: ... validation error for MetaAnalyzerResult ... impact Field required` or `findings ... Input should be a valid list`. Retry once; if it fails again, fall back to `--no-llm` for that skill.
- **Static mode over-flags.** Any `subprocess.run([...])` (even array-arg, no shell), env-var read, `urlopen`/`urllib` fetch, or browser-cookie access trips HIGH rules in legit skills. Binary files produce garbage matches (random bytes matching `rm`). Treat static HIGH as "look here," not "guilty."
- **Legit-but-powerful capabilities read as CRITICAL.** Browser-automation skills (cookie/session access, screen record), skills that shell out to `claude`/`gh`, or yt-dlp `--cookies-from-browser` will score high. Not bugs — inherent. The real question is whether you trust the source, not the rule hit.

## Notes

- The `skillspector` zsh function in `~/.zshrc` does the same thing interactively (mounts `$PWD`, auto-passes the key if set). This skill is for when Claude runs the scan and triages the output.
- Rebuild the image after pulling repo updates: `cd "$SKILLSPECTOR_REPO" && git pull && docker build -t skillspector .`
