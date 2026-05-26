# Contributing to amnesia

Thanks for your interest. amnesia is a small, focused plugin — contributions
are welcome when they solve a real problem that fits within the scope.

## What's in scope

- **Bug fixes** — incorrect behaviour in any hook, command, or the MCP server.
- **New hooks** — extending the event coverage (e.g. `PermissionRequest`,
  `Notification`) in a way that improves handoff quality without adding
  latency to the critical path.
- **MCP improvements** — additional read-only tools on `server.py`, or
  performance improvements to `recall` / `handoff_get`.
- **Documentation** — factual corrections, clearer explanations, updated
  version references.

**Out of scope:** general-purpose memory stores, cloud sync services as
first-class features, changes that break the zero-dependency guarantee for the
MCP server (stdlib only), or hooks that add visible latency to interactive turns.

## The review bar

A PR is ready to merge when it:

1. **Solves a real problem** — describe the failure mode or user-visible issue
   it addresses. "Nice to have" is not a reason to land.
2. **Isolates summarizer calls** — any new `claude -p` invocation must include
   `CLAUDE_CODE_DISABLE_CLAUDE_MDS=1 CLAUDE_CODE_DISABLE_AUTO_MEMORY=1` and an
   `--append-system-prompt` grounding instruction. Hallucination from CLAUDE.md
   content is a regression.
3. **Does not leak CLAUDE.md content** — verify empirically, not just by
   inspection. Run your new summarizer path against a transcript from a project
   with a distinctive CLAUDE.md and confirm the output contains no content from it.
4. **Pins via semver + sha** — any new dependency declared in
   `.claude-plugin/marketplace.json` or `plugin.json` must include both a
   semver version and a SHA digest. Floating references are not accepted.
5. **Tests pass** — `bash tests/smoke.sh` and `python3 tests/test-mcp-server.py`
   must both exit 0.

## How to test locally

```bash
# Syntax and unit tests
bash tests/smoke.sh

# MCP protocol layer
python3 tests/test-mcp-server.py

# Dependencies (Debian/Ubuntu)
sudo apt-get install -y jq python3
```

No pip packages needed. No API keys needed. The smoke suite runs in a temporary
isolated directory under `/tmp/amnesia-test-<pid>` and cleans up on exit.

To test against a real Claude Code session, install the plugin from your local
clone:

```bash
/plugin marketplace add /path/to/cloned/amnesia
/plugin install amnesia@88plug
/reload-plugins
```

## Commit message conventions

This repo follows [Conventional Commits](https://www.conventionalcommits.org/):

```
<type>(<scope>): <short description>

[optional body]

Co-Authored-By: Your Name <you@example.com>
```

Common types: `fix`, `feat`, `docs`, `refactor`, `test`, `chore`.
Scope is optional but helpful: `hooks`, `mcp`, `commands`, `lib`, `ci`.

Keep the subject line under 72 characters. Use the body for the *why*, not
the *what* (the diff shows the what).

## DCO / sign-off

This project does **not** require a Developer Certificate of Origin sign-off
(`Signed-off-by:` trailer). Submitting a PR is sufficient indication that you
have the right to contribute the code under the MIT license.

## Questions

Open an issue or start a discussion. There is no Slack or Discord.
