# ReelFactory — beta downloads

A floating panel that edits inside DaVinci Resolve. It drives Resolve through
its scripting API, so it does not replace Resolve or open your footage itself —
it builds timelines, captions, cuts, effects and renders in the project you
already have open.

This repository exists only to hand out builds. The source is private.

---

## Download

**[→ Latest build](../../releases/latest)**

Apple Silicon (M1/M2/M3/M4), macOS 12 or newer.

## Install

Full steps are in **[INSTALL.md](INSTALL.md)**. The short version:

1. Open the `.dmg`, drag **ReelFactory** into **Applications**.
2. Run this once in Terminal:

   ```
   xattr -dr com.apple.quarantine /Applications/ReelFactory.app
   ```

   The build is ad-hoc signed rather than notarized, so without this macOS
   reports it as damaged. It is not damaged — it carries no Apple-issued
   identity, and the system blocks it until told otherwise.
3. Launch it, open the **Setup** pane, and press **Install engine**.

Setup checks every dependency and names anything missing, so you can install
what you have and let it tell you the rest.

## Before you start

- DaVinci Resolve installed and launched at least once.
- Resolve → Preferences → System → General → **External scripting using: Local**
- `brew install ffmpeg`

Optional, for the transcription-based panes: `pip3 install mlx-whisper` and
`pip3 install demucs`.

## Reporting a problem

The activity log at the bottom of the panel is the real error message — send
that, along with what you pressed. [Open an issue](../../issues) or send it
directly.
