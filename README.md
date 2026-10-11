# CallScribe

A macOS menu bar app that records Microsoft Teams calls as two separate streams — your mic ("Me") and Teams' audio ("Others") — and turns them into speaker-labeled transcripts on-device.

**Status: Phase 1 of 5** — dual-stream capture, level meters, Test setup, pause/resume, crash-safe writing. Transcription, OneDrive output, calendar, installer, and auto-updates come in later phases.

Requirements: Apple Silicon, macOS 14.2+, Xcode Command Line Tools. No Xcode, no admin rights.

## Build and run (development)

```bash
scripts/build-app.sh
```

Builds `build/CallScribe.app`, signed with the self-signed **CallScribe Local** certificate. The first run creates that certificate in your login keychain (no admin) and keeps a backup in `~/Library/Application Support/CallScribe/Signing/`. Every build is signed with the same identity, so macOS keeps CallScribe's permissions across rebuilds.

```bash
open build/CallScribe.app
```

Other options: `--dev-adhoc` (ad-hoc signature, permissions reset on every rebuild) and `--unsigned` (assemble only).

Run the unit tests:

```bash
scripts/test.sh
```

## Using Phase 1

- **Start/stop:** menu bar → Start Recording, or **⌃⌥R**. **Pause/resume:** **⌃⌥P**.
- **Levels window** opens while recording, with a meter and status for each stream. Closing it doesn't stop the recording.
- **Test Setup…** runs a 15-second check: speak, then play audio in Teams or a browser. It reports whether each stream heard the right thing and whether either one picked up the other.
- **Settings** submenu: icon pulse, elapsed time in the menu bar, mic voice processing (off by default), and call audio source (Teams app, browsers, or automatic).
- Recordings: `~/Library/Application Support/CallScribe/Recordings/<session>/` → `me.wav`, `others.wav` (16 kHz mono), and `session.json`.
- Log: menu → View Log (`~/Library/Logs/CallScribe/callscribe.log`).

## How capture works

- **Me:** the default input device through AVAudioEngine. Follows headset unplug/replug.
- **Others:** a Core Audio process tap on Teams' processes (`com.microsoft.teams2*`, including helpers), or on Chrome/Edge/Safari for Teams on the web. It never captures system-wide output and never captures CallScribe itself. The tap is rebuilt when Teams restarts, the output device changes, or the Mac wakes.
- Both files share one timeline. If a stream stalls, silence is inserted so later audio stays aligned. If the call stream can't capture, the mic keeps recording and the menu bar shows a warning.
- Files are flushed to disk every 3 seconds. After a crash, the next launch repairs the WAV files and tells you.
- While the Mac sleeps, the recording pauses automatically and resumes on wake.

## Permissions

- **Microphone:** asked the first time you record.
- **System audio recording** (Privacy & Security → Screen & System Audio Recording → System Audio Recording Only): asked the first time the call stream starts.
