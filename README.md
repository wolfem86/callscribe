# CallScribe

A macOS menu bar app that records Microsoft Teams calls as two separate streams — your mic ("Me") and Teams' audio ("Others") — and turns them into speaker-labeled transcripts on-device.

**Status: Phase 3 of 5** — dual-stream capture, on-device transcription to OneDrive, and the recording details dialog. Calendar integration, the installer, and auto-updates come in later phases.

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

## Transcription (Phase 2)

- When a recording stops, CallScribe transcribes **Me** and **Others** separately, on-device, with WhisperKit (`openai_whisper-large-v3-v20240930_turbo_632MB`, downloaded once to `~/Library/Application Support/CallScribe/Models/`). The first use compiles the model for your Mac, which takes several minutes once; after that, a 2-minute call transcribes in about 10 seconds.
- **Headset leak filtering:** wired headsets often leak call audio into their own mic. CallScribe measures that leak and ignores it on the Me stream, and if the same words still appear in both streams at the same moment, the **Me** copy is dropped (logged as "Duplicate guard").
- **No transcribing silence:** only detected speech is sent to Whisper, region by region, so timestamps match the audio and Whisper's stock hallucinations ("Thank you.") are filtered out.
- **Output:** `<Title> - YYYY-MM-DD HHMM.md` in OneDrive → `Call Transcripts` (auto-detected under `~/Library/CloudStorage/OneDrive-*`; change it in Settings), with the matching `.json` in `Call Transcripts/.data/`. Files are written locally first and then moved in, so OneDrive never syncs partial files. If OneDrive isn't available, transcripts wait in `~/Library/Application Support/CallScribe/Outbox/` and move automatically when it's back.
- **Audio** is deleted once the transcript is saved (Settings → Keep Audio Locally to keep it 1–30 days). If transcription fails, the audio is kept and **Retry Transcription** appears in the menu.

## Recording details (Phase 3)

- When a recording stops, a **Recording Details** dialog opens while transcription runs in the background: title, date/time, organizer, participants (comma-separated), tags (suggested from tags you've used before), and notes.
- The transcript is written only once both are done. **Save** (or closing the window) keeps what's entered; **Discard Recording…** deletes the audio and transcript after confirming. If you ignore the dialog, it saves the pre-filled values after 10 minutes.
- **Recent Recordings** in the menu reopens the dialog for your last 20 recordings. Saving there rewrites the transcript header and renames the `.md` and `.json` if the title or date changed.
- A small local copy of each transcript (`transcript.json` next to `session.json`) makes later edits possible after the audio is deleted.

## How capture works

- **Me:** the default input device through AVAudioEngine. Follows headset unplug/replug.
- **Others:** a Core Audio process tap on Teams' processes (`com.microsoft.teams2*`, including helpers), or on Chrome/Edge/Safari for Teams on the web. It never captures system-wide output and never captures CallScribe itself. The tap is rebuilt when Teams restarts, the output device changes, or the Mac wakes.
- Both files share one timeline. If a stream stalls, silence is inserted so later audio stays aligned. If the call stream can't capture, the mic keeps recording and the menu bar shows a warning.
- Files are flushed to disk every 3 seconds. After a crash, the next launch repairs the WAV files and tells you.
- While the Mac sleeps, the recording pauses automatically and resumes on wake.

## Permissions

- **Microphone:** asked the first time you record.
- **System audio recording** (Privacy & Security → Screen & System Audio Recording → System Audio Recording Only): asked the first time the call stream starts.
