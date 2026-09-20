#!/bin/bash
# ReelFactory — beta installer.
#
#   curl -fsSL https://raw.githubusercontent.com/probuilderonsol/reelfactory-beta/main/install.sh | bash
#   curl -fsSL …/install.sh | bash -s doctor      # read-only report, nothing installed
#
# What it does, in order: checks this is an Apple Silicon Mac with DaVinci
# Resolve and Claude Code; installs the newest ReelFactory release into
# /Applications and the Dock; clears the download quarantine; installs ffmpeg
# and mlx-whisper through Homebrew + pipx; registers the DaVinci Resolve MCP
# server in Claude Code (user scope). Run it again to update.
#
# It never uses sudo itself. Homebrew's own installer asks for your password.
set -euo pipefail

# ── constants, all overridable so the whole thing can be tested against a fake HOME ──
RF_REPO="${RF_REPO:-probuilderonsol/reelfactory-beta}"
RF_APPS_DIR="${RF_APPS_DIR:-/Applications}"
RF_SUPPORT_DIR="${RF_SUPPORT_DIR:-$HOME/Library/Application Support/ReelFactory}"
RF_APP="$RF_APPS_DIR/ReelFactory.app"
RF_TAG_FILE="$RF_SUPPORT_DIR/installed-tag"
RF_MCP_DIR="${RF_MCP_DIR:-$RF_SUPPORT_DIR/davinci-resolve-mcp}"
RF_MCP_REPO="https://github.com/samuelgursky/davinci-resolve-mcp.git"
RF_MCP_NAME="davinci-resolve"
RESOLVE_APP="${RESOLVE_APP:-/Applications/DaVinci Resolve/DaVinci Resolve.app}"
RESOLVE_API="/Library/Application Support/Blackmagic Design/DaVinci Resolve/Developer/Scripting"
RESOLVE_LIB="$RESOLVE_APP/Contents/Libraries/Fusion/fusionscript.so"
# Test hooks: RF_DMG (local dmg instead of download), RF_RELEASE_JSON (local API
# response), RF_SKIP_BREW=1, RF_NO_DOCK=1, RF_NO_OPEN=1.

export PATH="/opt/homebrew/bin:/usr/local/bin:$HOME/.local/bin:$PATH"

# ── output ──
say()  { printf '→ %s\n' "$*"; }
skip() { printf '  · %s\n' "$*"; }
warn() { printf '  ! %s\n' "$*" >&2; }
die()  { printf '\n✗ %s\n' "$*" >&2; exit 1; }

# ── checks (pure: print one status line, return 0/1; shared by install and doctor) ──
check_arch() {
  [ "$(uname -m)" = "arm64" ] || { echo "Intel Mac — ReelFactory is Apple Silicon only"; return 1; }
  local major; major="$(sw_vers -productVersion | cut -d. -f1)"
  [ "$major" -ge 12 ] || { echo "macOS $(sw_vers -productVersion) — needs 12 or newer"; return 1; }
  echo "Apple Silicon, macOS $(sw_vers -productVersion)"
}

check_clt() {
  if xcode-select -p >/dev/null 2>&1; then echo "Xcode Command Line Tools: $(xcode-select -p)"; return 0; fi
  echo "Xcode Command Line Tools: missing"; return 1
}

check_resolve() {
  [ -d "$RESOLVE_APP" ] || { echo "DaVinci Resolve: not found at $RESOLVE_APP"; return 1; }
  [ -x "$RESOLVE_APP/Contents/Libraries/Fusion/fuscript" ] \
    || { echo "DaVinci Resolve: found, but no fuscript inside it"; return 1; }
  local v; v="$(defaults read "$RESOLVE_APP/Contents/Info.plist" CFBundleShortVersionString 2>/dev/null || echo '?')"
  echo "DaVinci Resolve $v"
}

# Where a fresh Claude Code lands: PATH, the native installer, or npm's global bin.
find_claude() {
  command -v claude 2>/dev/null && return 0
  [ -x "$HOME/.claude/local/claude" ] && { echo "$HOME/.claude/local/claude"; return 0; }
  local nb=""
  nb="$(npm prefix -g 2>/dev/null || true)"
  [ -n "$nb" ] && [ -x "$nb/bin/claude" ] && { echo "$nb/bin/claude"; return 0; }
  return 1
}
check_claude() {
  local c; c="$(find_claude)" || { echo "Claude Code: not installed"; return 1; }
  echo "Claude Code $("$c" --version 2>/dev/null | head -1) at $c"
}

# mcp[cli] needs 3.10+. /usr/bin/python3 is 3.9 on current macOS, so prefer
# Homebrew, then python.org, and only fall back to the system one.
find_python() {
  local p
  for p in /opt/homebrew/bin/python3 /Library/Frameworks/Python.framework/Versions/*/bin/python3 \
           /usr/local/bin/python3 /usr/bin/python3; do
    [ -x "$p" ] || continue
    "$p" -c 'import sys; sys.exit(0 if sys.version_info >= (3,10) else 1)' 2>/dev/null && { echo "$p"; return 0; }
  done
  return 1
}

check_tool() {  # check_tool <binary> <label>
  local b=""
  b="$(command -v "$1" 2>/dev/null || true)"
  [ -n "$b" ] || b="$(ls /Library/Frameworks/Python.framework/Versions/*/bin/"$1" 2>/dev/null | head -1 || true)"
  [ -n "$b" ] && { echo "$2: $b"; return 0; }
  echo "$2: not installed"; return 1
}

check_app() {
  [ -d "$RF_APP" ] || { echo "ReelFactory: not installed"; return 1; }
  local v t; v="$(defaults read "$RF_APP/Contents/Info.plist" CFBundleShortVersionString 2>/dev/null || echo '?')"
  t="$(installed_tag)"; echo "ReelFactory $v${t:+ ($t)} at $RF_APP"
}

check_mcp() {
  local c; c="$(find_claude)" || { echo "$RF_MCP_NAME: no Claude Code"; return 1; }
  if "$c" mcp get "$RF_MCP_NAME" >/dev/null 2>&1; then echo "$RF_MCP_NAME: registered in Claude Code"; return 0; fi
  echo "$RF_MCP_NAME: not registered in Claude Code"; return 1
}

check_mcp_import() {
  local py="$RF_MCP_DIR/venv/bin/python"
  [ -x "$py" ] || { echo "MCP venv: not built"; return 1; }
  if RESOLVE_SCRIPT_API="$RESOLVE_API" RESOLVE_SCRIPT_LIB="$RESOLVE_LIB" PYTHONPATH="$RESOLVE_API/Modules" \
       "$py" -c 'import DaVinciResolveScript' 2>/dev/null; then
    echo "MCP venv imports Resolve's scripting modules"; return 0
  fi
  echo "MCP venv: cannot import DaVinciResolveScript"; return 1
}

# ── release ──
# Prints three lines: tag, asset name, asset url. Reads the releases LIST and
# takes the first non-draft entry — NOT /releases/latest, which skips
# prereleases and 404s for every beta we have shipped.
pick_release() {
  local json
  if [ -n "${RF_RELEASE_JSON:-}" ]; then
    json="$(cat "$RF_RELEASE_JSON")"
  else
    json="$(curl -fsSL "https://api.github.com/repos/$RF_REPO/releases?per_page=10")" \
      || die "Could not reach GitHub. Download by hand: https://github.com/$RF_REPO/releases"
  fi
  printf '%s' "$json" | python3 -c '
import json, sys
rels = [r for r in json.load(sys.stdin) if not r.get("draft")]
if not rels: sys.exit("no published release")
r = rels[0]
dmgs = [a for a in r["assets"] if a["name"].endswith(".dmg")]
if not dmgs: sys.exit("release %s has no .dmg" % r["tag_name"])
print(r["tag_name"]); print(dmgs[0]["name"]); print(dmgs[0]["browser_download_url"])
'
}

installed_tag() { if [ -f "$RF_TAG_FILE" ]; then cat "$RF_TAG_FILE"; fi; }
remember_tag()  { mkdir -p "$(dirname "$RF_TAG_FILE")"; printf '%s' "$1" > "$RF_TAG_FILE"; }

# ── actions ──
# install_app <tag> <asset-name> <asset-url>
install_app() {
  local tag="$1" name="$2" url="$3"
  if [ -d "$RF_APP" ] && [ "$(installed_tag)" = "$tag" ]; then skip "ReelFactory $tag already installed"; return 0; fi
  local work dmg mnt
  work="$(mktemp -d)"
  if [ -n "${RF_DMG:-}" ]; then dmg="$RF_DMG"; else
    dmg="$work/$name"; say "Downloading $name"
    curl -fL --progress-bar -o "$dmg" "$url" || { rm -rf "$work"; die "Download failed. By hand: $url"; }
  fi
  mnt="$work/mnt"; mkdir -p "$mnt"
  hdiutil attach -nobrowse -readonly -quiet -mountpoint "$mnt" "$dmg" || { rm -rf "$work"; die "Could not open $dmg"; }
  if [ ! -d "$mnt/ReelFactory.app" ]; then hdiutil detach -quiet "$mnt" || true; rm -rf "$work"; die "No ReelFactory.app inside the dmg"; fi
  say "Installing ReelFactory $tag into $RF_APPS_DIR"
  rm -rf "$RF_APP"
  ditto "$mnt/ReelFactory.app" "$RF_APP"
  hdiutil detach -quiet "$mnt" || true
  rm -rf "$work"
  # Ad-hoc signed, not notarized: macOS calls it damaged until the download
  # quarantine flag is removed. It is not damaged.
  xattr -dr com.apple.quarantine "$RF_APP" 2>/dev/null || true
  remember_tag "$tag"
  [ -n "${RF_NO_DOCK:-}" ] || add_to_dock
}

dock_entry_xml() {
  printf '<dict><key>tile-data</key><dict><key>file-data</key><dict><key>_CFURLString</key><string>file://%s/</string><key>_CFURLStringType</key><integer>15</integer></dict></dict></dict>' "$RF_APP"
}
add_to_dock() {
  if defaults read com.apple.dock persistent-apps 2>/dev/null | grep -q "ReelFactory.app"; then skip "already in the Dock"; return 0; fi
  say "Adding ReelFactory to the Dock"
  if defaults write com.apple.dock persistent-apps -array-add "$(dock_entry_xml)"; then killall Dock 2>/dev/null || true
  else warn "Could not add to the Dock — drag it there from $RF_APPS_DIR"; fi
}

# ffmpeg and the whisper tools gate the caption panes only, so this whole
# step may fail without failing the install.
install_tools() {
  if [ -n "${RF_SKIP_BREW:-}" ]; then skip "skipping Homebrew (RF_SKIP_BREW)"; return 0; fi
  if ! command -v brew >/dev/null 2>&1; then
    say "Installing Homebrew (it will ask for your password once)"
    /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)" < /dev/tty \
      || { warn "Homebrew not installed. Captions need ffmpeg: install Homebrew from https://brew.sh then run this line again."; return 0; }
    export PATH="/opt/homebrew/bin:$PATH"
  fi
  local want=""
  if command -v ffmpeg >/dev/null 2>&1; then skip "ffmpeg present"; else want="$want ffmpeg"; fi
  if command -v pipx   >/dev/null 2>&1; then skip "pipx present";   else want="$want pipx"; fi
  if [ -n "$want" ]; then
    say "brew install$want"
    # shellcheck disable=SC2086
    brew install $want || { warn "brew install failed — run: brew install$want"; return 0; }
  fi
  local t bin
  for t in mlx-whisper demucs; do
    bin="${t/-/_}"
    if check_tool "$bin" "$bin" >/dev/null; then skip "$bin present"; continue; fi
    say "pipx install $t"
    pipx install "$t" >/dev/null 2>&1 || warn "$t did not install — run: pipx install $t"
  done
}

# Registers samuelgursky/davinci-resolve-mcp (MIT) in Claude Code at USER
# scope through `claude mcp add`, which merges into whatever servers the
# tester already has. Upstream's own installer writes ./.mcp.json — project
# scope — which is the wrong scope for this, so we use only its server.
install_bridge() {
  local claude py="" server="$RF_MCP_DIR/src/server.py" venv="$RF_MCP_DIR/venv"
  claude="$(find_claude)" || die "Claude Code is not installed. Get it at https://claude.com/claude-code then run this line again."
  py="$(find_python || true)"
  if [ -z "$py" ] && command -v brew >/dev/null 2>&1; then
    say "brew install python"; brew install python >/dev/null 2>&1 || true; py="$(find_python || true)"
  fi
  [ -n "$py" ] || die "Need Python 3.10 or newer for the Claude Code bridge. Install from https://python.org then run this line again."

  if [ -d "$RF_MCP_DIR/.git" ]; then
    say "Updating the DaVinci MCP server"
    git -C "$RF_MCP_DIR" pull -q --ff-only 2>/dev/null || warn "git pull failed — keeping the current server"
  else
    say "Fetching the DaVinci MCP server"; mkdir -p "$(dirname "$RF_MCP_DIR")"
    git clone -q --depth 1 "$RF_MCP_REPO" "$RF_MCP_DIR" || die "Could not clone $RF_MCP_REPO"
  fi

  if [ -x "$venv/bin/python" ] && "$venv/bin/python" -c 'import mcp' 2>/dev/null; then skip "MCP venv present"; else
    say "Building the MCP venv with $py"
    rm -rf "$venv"; "$py" -m venv "$venv" || die "venv failed. Retry after: rm -rf \"$venv\""
    "$venv/bin/pip" install -q --upgrade pip >/dev/null 2>&1 || true
    "$venv/bin/pip" install -q 'mcp[cli]' || die "pip install mcp[cli] failed (output above). Retry after: rm -rf \"$venv\""
  fi

  if "$claude" mcp get "$RF_MCP_NAME" 2>/dev/null | grep -q "$server"; then skip "$RF_MCP_NAME already registered in Claude Code"; else
    say "Registering $RF_MCP_NAME in Claude Code (user scope)"
    "$claude" mcp remove -s user "$RF_MCP_NAME" >/dev/null 2>&1 || true
    "$claude" mcp add -s user "$RF_MCP_NAME" -- "$venv/bin/python" "$server" \
      || die "claude mcp add failed. By hand: claude mcp add -s user $RF_MCP_NAME -- \"$venv/bin/python\" \"$server\""
  fi

  if check_mcp_import >/dev/null; then skip "bridge imports Resolve's scripting modules"
  else warn "The bridge cannot import Resolve's scripting modules yet — open Resolve once, then run doctor."; fi
}

# ── doctor: the same checks, read-only, formatted to paste back ──
doctor() {
  echo "ReelFactory doctor — $(date '+%Y-%m-%d %H:%M')"
  local f
  for f in check_arch check_clt check_resolve check_claude check_app; do
    printf '  %s %s\n' "$($f >/dev/null 2>&1 && echo '✓' || echo '✗')" "$($f 2>&1 || true)"
  done
  for f in ffmpeg mlx_whisper demucs; do
    printf '  %s %s\n' "$(check_tool "$f" "$f" >/dev/null && echo '✓' || echo '·')" "$(check_tool "$f" "$f" || true)"
  done
  printf '  %s %s\n' "$(check_mcp >/dev/null 2>&1 && echo '✓' || echo '✗')" "$(check_mcp 2>&1 || true)"
  printf '  %s %s\n' "$(check_mcp_import >/dev/null 2>&1 && echo '✓' || echo '✗')" "$(check_mcp_import 2>&1 || true)"
  echo "  · Resolve → Preferences → System → General → External scripting: must be Local (cannot be read from here)"
}

# ── main (runs only when not sourced by the tests) ──
main() {
  if [ "${1:-}" = "doctor" ]; then doctor; return 0; fi
  echo; say "ReelFactory installer"; echo
  local s
  s="$(check_arch)"    || die "$s"
  skip "$s"
  if ! s="$(check_clt)"; then
    say "Installing Xcode Command Line Tools — accept the dialog, then run this line again when it finishes."
    xcode-select --install 2>/dev/null || true; exit 0
  fi
  skip "$s"
  s="$(check_resolve)" || die "$s. Install DaVinci Resolve, open it once, then run this line again."
  skip "$s"
  s="$(check_claude)"  || die "$s. Install Claude Code from https://claude.com/claude-code then run this line again."
  skip "$s"
  echo

  local rel tag name url
  rel="$(pick_release)"
  tag="$(printf '%s' "$rel" | sed -n 1p)"; name="$(printf '%s' "$rel" | sed -n 2p)"; url="$(printf '%s' "$rel" | sed -n 3p)"
  install_app "$tag" "$name" "$url"
  echo
  install_tools
  echo
  install_bridge
  echo

  say "Done."
  echo "   ReelFactory $tag is in $RF_APPS_DIR and your Dock."
  echo "   Claude Code can drive DaVinci Resolve (server: $RF_MCP_NAME)."
  echo
  echo "   One thing only you can do — in DaVinci Resolve, once:"
  echo "     Preferences → System → General → External scripting using: Local"
  echo "   Then open ReelFactory → Setup → Install engine."
  echo
  echo "   Something wrong? Paste this back:  curl -fsSL https://raw.githubusercontent.com/$RF_REPO/main/install.sh | bash -s doctor"
  [ -n "${RF_NO_OPEN:-}" ] || open -a "DaVinci Resolve" 2>/dev/null || true
}

if [ -z "${RF_SOURCED:-}" ]; then main "$@"; fi
