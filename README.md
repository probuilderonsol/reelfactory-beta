# ReelFactory — beta

A floating panel that edits inside DaVinci Resolve, and a bridge so your
Claude Code can drive Resolve too.

## Install — paste this into Terminal

```
curl -fsSL https://raw.githubusercontent.com/probuilderonsol/reelfactory-beta/main/install.sh | bash
```

You need three things before you paste it: an **Apple Silicon Mac**,
**DaVinci Resolve** (opened at least once), and **Claude Code**. The line
checks for all three and tells you which one is missing.

Then, once, in Resolve: **Preferences → System → General → External scripting
using: Local**. The installer opens Resolve for you at the end and prints this
reminder. After that, open ReelFactory from the Dock → **Setup** → **Install
engine**.

**To update:** paste the same line again.

## What the line does

Nothing hidden — [read it](install.sh) before you run it. In order:

1. Checks Apple Silicon, macOS 12+, Xcode Command Line Tools, Resolve, Claude Code. Stops and says what to install if one is missing.
2. Downloads the newest release into `/Applications`, adds it to the Dock, and clears the download quarantine (the app is ad-hoc signed, so macOS would otherwise call it "damaged" — it is not).
3. Installs `ffmpeg`, `mlx-whisper` and `demucs` through Homebrew and pipx. Homebrew asks for your password once. If you skip it, everything works except the caption panes.
4. Sets up the [DaVinci Resolve MCP server](https://github.com/samuelgursky/davinci-resolve-mcp) (MIT) in Claude Code — user scope, so it works in every folder. Your other MCP servers are untouched.

It never runs `sudo` itself and never edits Claude Code's config except through `claude mcp`.

## Something wrong?

```
curl -fsSL https://raw.githubusercontent.com/probuilderonsol/reelfactory-beta/main/install.sh | bash -s doctor
```

Paste the output, plus the activity log from the bottom of the panel, into an
[issue](../../issues) or send it directly.

Manual install, uninstall, and the full walkthrough: **[INSTALL.md](INSTALL.md)**.
Older builds: **[releases](../../releases)**.
