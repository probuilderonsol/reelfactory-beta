# ReelFactory — beta install

An editing panel that floats on top of DaVinci Resolve. It drives Resolve
through its scripting API, so it does not replace Resolve or open your footage
itself — it builds timelines, captions, cuts and effects in the project you
already have open.

This build is **unsigned**. It is handed out directly rather than sold or
listed, which means macOS will refuse to open it until you allow it once. That
is expected and the steps are below.

---

## 1. What you need first

| | |
|---|---|
| **macOS** | 12 or newer, Apple Silicon (M1/M2/M3/M4) |
| **DaVinci Resolve** | Installed and launched at least once. Studio is not required for most panes, but external scripting is. |
| **Scripting enabled** | Resolve → Preferences → System → General → **External scripting using: Local** |
| **ffmpeg** | `brew install ffmpeg` |

Two optional tools unlock the transcription-based panes. Skip them and
everything else still works:

```
pip3 install mlx-whisper     # captions, talking-head cuts
pip3 install demucs          # lyric timing against music
```

The app's **Setup** pane checks all of this for you and names anything missing,
so install what you have and let it tell you the rest.

## 2. Install

1. Open `ReelFactory-1.0.0-arm64.dmg` and drag **ReelFactory** into
   **Applications**.
2. Remove the download quarantine flag. Open Terminal and run:

   ```
   xattr -dr com.apple.quarantine /Applications/ReelFactory.app
   ```

   Without this macOS reports the app as damaged. It is not damaged — an
   unsigned app carries no Apple-issued identity, so the system blocks it
   until told otherwise. (Right-click → Open, the old workaround, no longer
   clears this on current macOS.)
3. Launch it. You should get a small translucent panel in the top-right of
   your screen.

## 3. First run

Open the **Setup** pane (the gear at the bottom of the icon rail).

1. Everything green means you are ready. Anything red is blocking and names its
   own fix; anything amber is an optional pane that will not work yet.
2. Press **Install engine**. This copies the Python half of ReelFactory into
   Resolve's own scripts folder, which is the only place Resolve will run a
   script from. Do this again after any app update.
3. Check the **folders** section. Rendered reels, caption plans and SRTs go to
   the paths listed there; change any of them if your library lives elsewhere.

Then open a project in Resolve. The panel's status dot goes green once it can
reach it.

## 4. Living with an overlay

- **Drag** it by its title bar.
- **▾** collapses it to just that bar, so it stops covering your timeline
  without disappearing. Double-clicking the bar does the same.
- **◈** toggles whether it stays above Resolve. On by default, including over a
  fullscreen Resolve.
- **⤢** switches to a normal resizable window, for when you have the screen
  space. It remembers a separate size and position for each mode.
- **Control + Option + R** hides and shows it from anywhere.

## 5. Things worth knowing

- **One job at a time.** Resolve's scripting engine does not tolerate
  concurrent scripts, so the app runs them one at a time and the activity log
  at the bottom tells you what is happening.
- **Don't quit Resolve mid-job.** The engine loses its handle on the project
  and the job fails; the app reconnects on the next action.
- **The AI steps are off.** A few features (hook refill, the edit brains) call
  the `claude` CLI and bill whoever is signed into it. They default to off and
  live behind the "use Claude" switch in Tools. Captions, effects, grades and
  renders never touch it — transcription and audio work run locally.
- **Long jobs are long.** Transcribing a media pool is minutes per clip the
  first time; results are cached, so the second run is fast.

## 6. When something breaks

- **A pane says a script is missing** — press Install engine in Setup.
- **"Resolve offline"** — open a project in Resolve, then click anything in the
  app. It reconnects on the next action, not on a timer.
- **The app won't open and nothing happens** — it is almost certainly the
  quarantine flag from step 2. Run the `xattr` command.
- **Everything else** — the activity log at the bottom of the panel is the
  real error message. Send that.
