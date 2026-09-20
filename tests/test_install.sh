#!/bin/bash
# tests/test_install.sh — sources install.sh and checks each piece, then runs
# the whole installer cold against a fake HOME. Nothing on this Mac is written.
# Run: bash tests/test_install.sh
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
PASS=0; FAIL=0
ok()   { PASS=$((PASS+1)); printf '  ok   %s\n' "$1"; }
fail() { FAIL=$((FAIL+1)); printf '  FAIL %s\n       %s\n' "$1" "${2:-}"; }
assert_eq() { [ "$2" = "$3" ] && ok "$1" || fail "$1" "expected [$3] got [$2]"; }
assert_contains() { case "$2" in *"$3"*) ok "$1";; *) fail "$1" "missing [$3] in: $2";; esac; }

# Source the installer without running it.
RF_SOURCED=1 . "$ROOT/install.sh"
set +e   # the installer sets -e; the tests want to keep going

echo "== helpers"
assert_eq "say prints its line" "$(say hello 2>&1)" "→ hello"
assert_eq "skip prints its line" "$(skip already 2>&1)" "  · already"

echo "== release"
out="$(RF_RELEASE_JSON="$HERE/fixtures/releases.json" pick_release)"
assert_eq "skips drafts, takes newest tag" "$(printf '%s' "$out" | sed -n 1p)" "v1.0.0-beta.1"
assert_eq "picks the .dmg asset, not the blockmap" "$(printf '%s' "$out" | sed -n 2p)" "ReelFactory-1.0.0-arm64.dmg"
assert_contains "asset url is the tag download url" "$(printf '%s' "$out" | sed -n 3p)" "/releases/download/v1.0.0-beta.1/"

tmp="$(mktemp -d)"
RF_TAG_FILE="$tmp/installed-tag"
assert_eq "no tag file → empty" "$(installed_tag)" ""
remember_tag "v1.0.0-beta.1"
assert_eq "remember_tag round-trips" "$(installed_tag)" "v1.0.0-beta.1"
rm -rf "$tmp"

echo "== checks"
assert_eq "arch check passes on this Mac" "$(check_arch >/dev/null && echo yes)" "yes"
assert_eq "resolve found here" "$(check_resolve >/dev/null && echo yes)" "yes"
assert_eq "resolve missing → fails" "$(RESOLVE_APP=/nonexistent check_resolve >/dev/null 2>&1 || echo no)" "no"
assert_eq "claude found here" "$(find_claude | grep -c claude)" "1"
py="$(find_python)"; assert_contains "find_python returns a python3" "$py" "python3"
assert_eq "find_python is >= 3.10" "$("$py" -c 'import sys; print(sys.version_info >= (3,10))')" "True"

echo "== doctor"
d="$(doctor 2>&1)"
assert_contains "doctor reports macOS" "$d" "macOS"
assert_contains "doctor reports Resolve" "$d" "DaVinci Resolve"
assert_contains "doctor reports Claude Code" "$d" "Claude Code"
assert_contains "doctor reports ffmpeg" "$d" "ffmpeg"
assert_contains "doctor reports the MCP server" "$d" "davinci-resolve"

echo "== install_app"
DMG_LOCAL="$HOME/Desktop/ReelFactory-beta/ReelFactory-1.0.0-arm64.dmg"
if [ -f "$DMG_LOCAL" ]; then
  tmp="$(mktemp -d)"
  RF_APPS_DIR="$tmp/Applications"; RF_APP="$RF_APPS_DIR/ReelFactory.app"
  RF_TAG_FILE="$tmp/support/installed-tag"
  mkdir -p "$RF_APPS_DIR"
  RF_DMG="$DMG_LOCAL" RF_NO_DOCK=1 install_app "v1.0.0-beta.1" "ReelFactory-1.0.0-arm64.dmg" "https://example.invalid/never" >/dev/null
  assert_eq "app copied" "$([ -x "$RF_APP/Contents/MacOS/ReelFactory" ] && echo yes)" "yes"
  assert_eq "quarantine cleared" "$(xattr -l "$RF_APP" | grep -c quarantine)" "0"
  assert_eq "tag remembered" "$(installed_tag)" "v1.0.0-beta.1"
  out="$(RF_DMG="$DMG_LOCAL" RF_NO_DOCK=1 install_app "v1.0.0-beta.1" "x.dmg" "u" 2>&1)"
  assert_contains "same tag → skipped" "$out" "already installed"
  assert_contains "dock entry xml names the app" "$(dock_entry_xml)" "ReelFactory.app"
  rm -rf "$tmp"
else
  echo "  (skipped: no local dmg at $DMG_LOCAL)"
fi

echo "== tools"
out="$(RF_SKIP_BREW=1 install_tools 2>&1)"
assert_contains "RF_SKIP_BREW skips Homebrew" "$out" "skipping Homebrew"
out="$(install_tools 2>&1)"
assert_contains "ffmpeg present → skipped" "$out" "ffmpeg"

echo "== bridge (cold, fake HOME)"
fake="$(mktemp -d)"; mkdir -p "$fake/.claude"
before="$(stat -f %m "$HOME/.claude.json" 2>/dev/null || echo 0)"
RF_MCP_DIR="$fake/support/davinci-resolve-mcp"
HOME="$fake" CLAUDE_CONFIG_DIR="$fake/.claude" install_bridge >/dev/null 2>&1
assert_eq "clone present" "$([ -f "$RF_MCP_DIR/src/server.py" ] && echo yes)" "yes"
assert_eq "venv imports mcp" "$("$RF_MCP_DIR/venv/bin/python" -c 'import mcp; print("yes")')" "yes"
assert_eq "venv imports Resolve modules" "$(check_mcp_import >/dev/null && echo yes)" "yes"
assert_contains "registered in the FAKE claude config" \
  "$(HOME="$fake" CLAUDE_CONFIG_DIR="$fake/.claude" "$(find_claude)" mcp get davinci-resolve 2>&1)" "server.py"
after="$(stat -f %m "$HOME/.claude.json" 2>/dev/null || echo 0)"
assert_eq "real ~/.claude.json untouched" "$after" "$before"
out="$(HOME="$fake" CLAUDE_CONFIG_DIR="$fake/.claude" install_bridge 2>&1)"
assert_contains "second run skips registration" "$out" "already registered"
rm -rf "$fake"

echo "== main (cold)"
if [ -f "$DMG_LOCAL" ]; then
  fake="$(mktemp -d)"; mkdir -p "$fake/.claude" "$fake/Applications"
  out="$(HOME="$fake" CLAUDE_CONFIG_DIR="$fake/.claude" RF_APPS_DIR="$fake/Applications" \
         RF_SUPPORT_DIR="$fake/support" RF_DMG="$DMG_LOCAL" RF_RELEASE_JSON="$HERE/fixtures/releases.json" \
         RF_SKIP_BREW=1 RF_NO_DOCK=1 RF_NO_OPEN=1 bash "$ROOT/install.sh" 2>&1)"
  assert_contains "main installed the app" "$out" "Installing ReelFactory v1.0.0-beta.1"
  assert_contains "main registered the bridge" "$out" "Registering davinci-resolve"
  assert_contains "main prints the Resolve preference step" "$out" "External scripting"
  assert_eq "app in the fake Applications" "$([ -d "$fake/Applications/ReelFactory.app" ] && echo yes)" "yes"
  assert_eq "doctor mode is read-only" "$(HOME="$fake" RF_APPS_DIR=/nonexistent bash "$ROOT/install.sh" doctor 2>&1 | grep -c 'Installing')" "0"
  rm -rf "$fake"
fi

echo
printf '%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
