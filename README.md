# CallScribe

A macOS menu bar app that records Microsoft Teams calls as two separate streams — your mic ("Me") and Teams' audio ("Others") — and turns them into speaker-labeled transcripts on-device.

**Status: Phase 4 in progress** — dual-stream capture, on-device transcription to OneDrive, the recording details dialog, and meeting details from Outlook via Power Automate. Reminders, auto-detection, the installer, and auto-updates come next.

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

- **Start/stop:** menu bar → Start Recording, or **⌃⌥R**. **Pause/resume:** **⌃⌥P**. **Call details while recording:** **⌃⌥D**.
- **Levels window:** a meter and status for each stream. During a recording, show or hide it from the menu (**Show/Hide Levels Window**); Settings → **Open Levels Window When Recording** opens it automatically (off by default). Closing it doesn't stop the recording.
- **Test Setup…** runs a 15-second check: speak, then play audio in Teams or a browser. It reports whether each stream heard the right thing and whether either one picked up the other.
- **Settings** submenu: icon pulse, elapsed time in the menu bar, levels window on start, mic voice processing (off by default), call audio source (Teams app, browsers, or automatic), transcripts folder, and how long to keep audio.
- Recordings: `~/Library/Application Support/CallScribe/Recordings/<session>/` → `me.wav`, `others.wav` (16 kHz mono), and `session.json`.
- Log: menu → View Log (`~/Library/Logs/CallScribe/callscribe.log`).

## Transcription (Phase 2)

- When a recording stops, CallScribe transcribes **Me** and **Others** separately, on-device, with WhisperKit (`openai_whisper-large-v3-v20240930_turbo_632MB`, downloaded once to `~/Library/Application Support/CallScribe/Models/`). The first use compiles the model for your Mac, which takes several minutes once; after that, a 2-minute call transcribes in about 10 seconds.
- **Headset leak filtering:** wired headsets often leak call audio into their own mic. CallScribe measures that leak and ignores it on the Me stream, and if the same words still appear in both streams at the same moment, the **Me** copy is dropped (logged as "Duplicate guard").
- **No transcribing silence:** only detected speech is sent to Whisper, region by region, so timestamps match the audio and Whisper's stock hallucinations ("Thank you.") are filtered out.
- **Output:** `<Title> - YYYY-MM-DD HHMM.md` in OneDrive → `Call Transcripts` (auto-detected under `~/Library/CloudStorage/OneDrive-*`; change it in Settings), with the matching `.json` in `Call Transcripts/.data/`. Files are written locally first and then moved in, so OneDrive never syncs partial files. If OneDrive isn't available, transcripts wait in `~/Library/Application Support/CallScribe/Outbox/` and move automatically when it's back.
- **Audio** is deleted once the transcript is saved (Settings → Keep Audio Locally to keep it 1–30 days). If transcription fails, the audio is kept and **Retry Transcription** appears in the menu.

## Recording details (Phase 3)

- When a recording stops, a **Recording Details** dialog opens while transcription runs in the background, in this order: title, participants (comma-separated), notes, tags (suggested from tags you've used before), then start and end date/time — both pre-filled from the actual recording (moving the start moves the end with it).
- The transcript is written only once both are done. **Save** (or closing the window) keeps what's entered; **Discard Recording…** deletes the audio and transcript after confirming. If you ignore the dialog, it saves the pre-filled values after 10 minutes.
- **During a call**, choose **Edit Call Details…** in the menu (or **⌃⌥D**, or **Details…** in the control window) to fill in the same fields while recording. End is filled in when the recording stops, and you won't be asked again afterwards.
- **Recent Recordings** in the menu reopens the dialog for your last 20 recordings. Saving there rewrites the transcript header and renames the `.md` and `.json` if the title or start time changed.
- A small local copy of each transcript (`transcript.json` next to `session.json`) makes later edits possible after the audio is deleted.

## Meeting details from Outlook (Power Automate)

CallScribe pre-fills each recording's details (title, scheduled time, organizer, invitees, Teams link, and agenda without the Teams join boilerplate) from a calendar file that a **Power Automate** flow keeps up to date in your OneDrive. This needs no IT approval or app registration: the flow runs as you, with access to your own calendar. If no event matches, the **Teams call window's title** (meeting name, or "Call with Jane Smith") is used instead, which needs the Accessibility permission.

### Set up the flow (about 5 minutes, once)

1. Go to **make.powerautomate.com** and sign in with your work account.
2. **Create → Scheduled cloud flow.** Name it `CallScribe calendar`, set it to repeat every **15 minutes**, and click **Create**.
3. Add the action **Get calendar view of events (V3)** (Office 365 Outlook):
   - **Calendar Id:** Calendar
   - **Start Time:** expression `addHours(utcNow(), -12)`
   - **End Time:** expression `addDays(utcNow(), 7)`
4. Add the action **Create file** (OneDrive for Business):
   - **Folder Path:** `/CallScribe`
   - **File Name:** `calendar.json`
   - **File Content:** dynamic content **Body** from *Get calendar view of events (V3)*
5. **Save**, then **Test → Manually → Run**. Check that OneDrive now has `CallScribe/calendar.json`.
6. On your Mac, in Finder, right-click `OneDrive → CallScribe → calendar.json` → **Always Keep on This Device**.

If the second scheduled run fails with "a file with the same name already exists", replace the **Create file** step with **Update file** (OneDrive for Business), with **File** set to `/CallScribe/calendar.json` and the same **File Content**.

The CallScribe menu shows the calendar status, e.g. "Calendar: 12 upcoming events · updated 4 min ago". If your file is somewhere else, use Settings → **Calendar File…**. The file stays in your own OneDrive; CallScribe only reads it.

### How events are matched

A recording is matched to the event that's in progress when it starts, or that starts within 15 minutes of it, preferring Teams meetings and then the closest start time. It's checked again when the recording stops. Matched details pre-fill the dialog (and **⌃⌥D** during the call); everything stays editable. Past participants are also suggested as you type names.

## How capture works

- **Me:** the default input device through AVAudioEngine. Follows headset unplug/replug.
- **Others:** a Core Audio process tap on Teams' processes (`com.microsoft.teams2*`, including helpers), or on Chrome/Edge/Safari for Teams on the web. It never captures system-wide output and never captures CallScribe itself. The tap is rebuilt when Teams restarts, the output device changes, or the Mac wakes.
- Both files share one timeline. If a stream stalls, silence is inserted so later audio stays aligned. If the call stream can't capture, the mic keeps recording and the menu bar shows a warning.
- Files are flushed to disk every 3 seconds. After a crash, the next launch repairs the WAV files and tells you.
- While the Mac sleeps, the recording pauses automatically and resumes on wake.

## Permissions

- **Microphone:** asked the first time you record.
- **System audio recording** (Privacy & Security → Screen & System Audio Recording → System Audio Recording Only): asked the first time the call stream starts.
