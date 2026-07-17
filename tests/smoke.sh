#!/usr/bin/env bash
# amnesia smoke tests
#
# Usage: bash tests/smoke.sh
#
# Runs from the repository root. Requires: bash, jq, python3.
# Does NOT require claude or any network access.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
COMMON_SH="$REPO_ROOT/plugins/amnesia/hooks/lib/common.sh"
MCP_SERVER="$REPO_ROOT/plugins/amnesia/mcp/server.py"
HOOKS_DIR="$REPO_ROOT/plugins/amnesia/hooks"
PLUGIN_DIR="$REPO_ROOT/plugins/amnesia"

TEST_DIR="/tmp/amnesia-test-$$"
PASS=0
FAIL=0

# ---------------------------------------------------------------------------
# Cleanup
# ---------------------------------------------------------------------------
cleanup() {
  rm -rf "$TEST_DIR"
}
trap cleanup EXIT

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
ok() {
  printf '  [PASS] %s\n' "$1"
  PASS=$((PASS + 1))
}

fail() {
  printf '  [FAIL] %s\n' "$1"
  FAIL=$((FAIL + 1))
}

assert_eq() {
  local label="$1" got="$2" want="$3"
  if [ "$got" = "$want" ]; then
    ok "$label"
  else
    fail "$label — got: $(printf '%q' "$got")  want: $(printf '%q' "$want")"
  fi
}

assert_contains() {
  local label="$1" haystack="$2" needle="$3"
  if printf '%s' "$haystack" | grep -qF "$needle"; then
    ok "$label"
  else
    fail "$label — '$needle' not found in output"
  fi
}

assert_not_contains() {
  local label="$1" haystack="$2" needle="$3"
  if ! printf '%s' "$haystack" | grep -qF "$needle"; then
    ok "$label"
  else
    fail "$label — '$needle' should NOT appear in output"
  fi
}

# ---------------------------------------------------------------------------
# Setup: isolated project env
# ---------------------------------------------------------------------------
mkdir -p "$TEST_DIR"
export CLAUDE_PLUGIN_DATA="$TEST_DIR/plugin-data"
export CLAUDE_PROJECT_DIR="$TEST_DIR/myproject"
mkdir -p "$CLAUDE_PROJECT_DIR"

printf '\n=== amnesia smoke tests ===\n\n'

# ---------------------------------------------------------------------------
# 1. common.sh syntax check
# ---------------------------------------------------------------------------
echo ''
echo '--- 1. common.sh syntax ---'
if bash -n "$COMMON_SH" 2>/dev/null; then
  ok "bash -n common.sh"
else
  fail "bash -n common.sh"
fi

# ---------------------------------------------------------------------------
# 2. Source common.sh and run helpers
# ---------------------------------------------------------------------------
echo ''
echo '--- 2. Helper functions ---'

# Source in a subshell so set -e doesn't kill the test runner on a bad exit.
HELPER_OUT="$(bash --norc --noprofile -c "
  set -euo pipefail
  export CLAUDE_PLUGIN_DATA='$TEST_DIR/plugin-data'
  export CLAUDE_PROJECT_DIR='$TEST_DIR/myproject'
  source '$COMMON_SH'

  # amnesia::log_jsonl
  amnesia::log_jsonl 'smoke' 'test_event' 'k1=hello' 'k2=42'
  state_dir=\"\$(amnesia::state_dir)\"
  if [ -f \"\$state_dir/logs/events.jsonl\" ]; then
    echo 'log_jsonl:ok'
  else
    echo 'log_jsonl:fail'
  fi

  # amnesia::lock / unlock
  if amnesia::lock testlock 5; then
    amnesia::unlock testlock
    echo 'lock_unlock:ok'
  else
    echo 'lock_unlock:fail'
  fi

  # amnesia::git_state (non-git dir → empty object or valid JSON)
  gs=\"\$(amnesia::git_state)\"
  if printf '%s' \"\$gs\" | python3 -c 'import json,sys; json.load(sys.stdin)' 2>/dev/null; then
    echo 'git_state:valid_json'
  else
    echo 'git_state:invalid_json'
  fi

  # amnesia::rotate_jsonl — feed it a file that exceeds 5-line limit
  tmpjsonl=\"\$state_dir/test-rotate.jsonl\"
  for i in \$(seq 1 10); do printf '{\"n\":%d}\n' \"\$i\"; done > \"\$tmpjsonl\"
  AMNESIA_WS_MAX_LINES=5 amnesia::rotate_jsonl \"\$tmpjsonl\" 5
  remaining=\$(wc -l < \"\$tmpjsonl\")
  echo \"rotate_jsonl_remaining:\$remaining\"
" 2>/dev/null)"

assert_contains "amnesia::log_jsonl writes events.jsonl" "$HELPER_OUT" "log_jsonl:ok"
assert_contains "amnesia::lock/unlock succeeds"         "$HELPER_OUT" "lock_unlock:ok"
assert_contains "amnesia::git_state returns valid JSON" "$HELPER_OUT" "git_state:valid_json"
assert_contains "amnesia::rotate_jsonl keeps tail"      "$HELPER_OUT" "rotate_jsonl_remaining:5"

# ---------------------------------------------------------------------------
# 3. amnesia::redact_secrets
# ---------------------------------------------------------------------------
echo ''
echo '--- 3. redact_secrets ---'

redact() { bash --norc --noprofile -c "source '$COMMON_SH' 2>/dev/null; printf '%s' \"\$1\" | amnesia::redact_secrets" -- "$1" 2>/dev/null; }

out1="$(redact 'Authorization: Bearer abc123XYZverylongtoken')"
assert_not_contains "Bearer token redacted"     "$out1" "abc123XYZverylongtoken"
assert_contains     "Bearer sentinel present"   "$out1" "REDACTED"

out2="$(redact '--token=supersecretval')"
assert_not_contains "--token= value redacted"   "$out2" "supersecretval"
assert_contains     "--token= sentinel present" "$out2" "REDACTED"

out3="$(redact 'GITHUB_TOKEN=ghp_aBcDeFgHiJkLmNoPqRsT12')"
assert_not_contains "GITHUB_TOKEN value redacted"   "$out3" "ghp_aBcDeFgHiJkLmNoPqRsT12"
assert_contains     "GITHUB_TOKEN sentinel present" "$out3" "REDACTED"

out4="$(redact 'aws configure set aws_access_key_id AKIAIOSFODNN7EXAMPLE')"
assert_not_contains "AKIA token redacted"    "$out4" "AKIAIOSFODNN7EXAMPLE"
assert_contains     "AKIA sentinel present"  "$out4" "REDACTED"

out5="$(redact 'this line has no secrets')"
assert_contains     "clean line passes through" "$out5" "this line has no secrets"

# ---------------------------------------------------------------------------
# 4. bash -n on every hook .sh
# ---------------------------------------------------------------------------
echo ''
echo '--- 4. Hook syntax checks (bash -n) ---'

while IFS= read -r hook; do
  name="$(basename "$hook")"
  if bash -n "$hook" 2>/dev/null; then
    ok "bash -n $name"
  else
    fail "bash -n $name"
  fi
done < <(find "$HOOKS_DIR" -maxdepth 3 -name '*.sh' | sort)

# ---------------------------------------------------------------------------
# 5. Python syntax check on MCP server + launcher resolution
# ---------------------------------------------------------------------------
echo ''
echo '--- 5. MCP server syntax + run-python launcher ---'

RUN_PYTHON="$PLUGIN_DIR/scripts/run-python.sh"
MCP_LAUNCHER="$PLUGIN_DIR/scripts/mcp-server.sh"

if [ -x "$RUN_PYTHON" ] || [ -f "$RUN_PYTHON" ]; then
  ok "run-python.sh present"
else
  fail "run-python.sh present"
fi
if [ -f "$MCP_LAUNCHER" ]; then
  ok "mcp-server.sh present"
else
  fail "mcp-server.sh present"
fi

if bash "$RUN_PYTHON" -c "import ast; ast.parse(open('$MCP_SERVER').read())" 2>/dev/null; then
  ok "run-python.sh ast.parse(server.py)"
else
  fail "run-python.sh ast.parse(server.py)"
fi

# Thin PATH (simulates Claude GUI spawn): only /usr/bin + /bin. Must still find
# a system python3 or absolute fallback — never depend on interactive shell PATH.
THIN_OUT="$(env -i HOME="$HOME" PATH="/usr/bin:/bin" bash "$RUN_PYTHON" -c 'import sys; print(sys.version_info[0])' 2>/dev/null || true)"
if [ "$THIN_OUT" = "3" ]; then
  ok "run-python.sh works under thin PATH=/usr/bin:/bin"
else
  # Some minimal images lack /usr/bin/python3 entirely — soft-fail with note.
  if [ -x /usr/bin/python3 ] || [ -x /opt/homebrew/bin/python3 ]; then
    fail "run-python.sh works under thin PATH (got: $(printf '%q' "$THIN_OUT"))"
  else
    ok "run-python.sh thin PATH skipped (no system python3 on this host)"
  fi
fi

# Override must win.
FAKE_PY="$TEST_DIR/fake-python"
cat > "$FAKE_PY" <<'EOF'
#!/usr/bin/env bash
# pretend python that reports 3.12 and echoes a marker
if [ "$1" = "-c" ]; then
  case "$2" in
    *version_info*) exit 0 ;;
    *sys.executable*) echo "$0" ;;
    *) echo "FAKE_OK" ;;
  esac
  exit 0
fi
exit 0
EOF
chmod +x "$FAKE_PY"
# Override path must be a real Python for version_ok — use real python with env.
OVERRIDE_OUT="$(EIGHTYEIGHT_PYTHON="$(command -v python3 || command -v python)" bash "$RUN_PYTHON" -c 'import sys; print("override-ok")' 2>/dev/null || true)"
if [ "$OVERRIDE_OUT" = "override-ok" ]; then
  ok "EIGHTYEIGHT_PYTHON override works"
else
  fail "EIGHTYEIGHT_PYTHON override works (got: $(printf '%q' "$OVERRIDE_OUT"))"
fi

# Manifests must not use bare python3 (PATH-fragile under Claude spawn).
for mf in "$PLUGIN_DIR/.claude-plugin/plugin.json" "$PLUGIN_DIR/.mcp.json"; do
  if [ -f "$mf" ] && grep -qE '"command"[[:space:]]*:[[:space:]]*"python3?"' "$mf"; then
    fail "no bare python3 command in $(basename "$(dirname "$mf")")/$(basename "$mf")"
  else
    ok "no bare python3 in $(echo "$mf" | sed "s|$REPO_ROOT/||")"
  fi
done

# mcp-server.sh is invokable (will hang on stdio if we don't kill — just bash -n)
if bash -n "$MCP_LAUNCHER" 2>/dev/null; then
  ok "bash -n mcp-server.sh"
else
  fail "bash -n mcp-server.sh"
fi
if bash -n "$RUN_PYTHON" 2>/dev/null; then
  ok "bash -n run-python.sh"
else
  fail "bash -n run-python.sh"
fi

# ---------------------------------------------------------------------------
# 6. jq empty on every .json in the plugin
# ---------------------------------------------------------------------------
echo ''
echo '--- 6. JSON validity (jq empty) ---'

if command -v jq >/dev/null 2>&1; then
  while IFS= read -r jf; do
    rel="${jf#$REPO_ROOT/}"
    if jq empty "$jf" 2>/dev/null; then
      ok "jq empty $rel"
    else
      fail "jq empty $rel"
    fi
  done < <(find "$PLUGIN_DIR" -name '*.json' | sort)
else
  fail "jq not installed — skipping JSON validity checks"
fi

# ---------------------------------------------------------------------------
# 7. Fixture JSONL is valid JSON per line
# ---------------------------------------------------------------------------
echo ''
echo '--- 7. Fixture JSONL validity ---'

FIXTURE="$REPO_ROOT/tests/fixtures/sample-transcript.jsonl"
bad_lines=0
while IFS= read -r line; do
  [ -z "$line" ] && continue
  if ! printf '%s' "$line" | python3 -c "import json,sys; json.loads(sys.stdin.read())" 2>/dev/null; then
    bad_lines=$((bad_lines + 1))
  fi
done < "$FIXTURE"

if [ "$bad_lines" -eq 0 ]; then
  ok "sample-transcript.jsonl: all lines valid JSON"
else
  fail "sample-transcript.jsonl: $bad_lines invalid line(s)"
fi

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
printf '\n=== Results: %d passed, %d failed ===\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
