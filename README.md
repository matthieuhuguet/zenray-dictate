## 4 October 2026: Immediate 0.1 s out / 0.1 s in result transition

Version 3.6 build 9 begins the right-to-bottom-center transition as soon as the microphone stops. It fades out for 0.1 seconds, relocates while transparent, then fades in for 0.1 seconds. The final real Gemini witness measures 0.203240 seconds between animation start and completion, including AppKit scheduling. (4 October 2026)

The 900 ms transcript-stability guard still protects clipboard/history completion, but no longer delays the visible result. Late Gemini edits update the same native DOM in the bottom-center capsule. Clicking outside can dismiss this result while final text settles; completion does not reopen a dismissed capsule. Recording remains visible at right and cancelled/interrupted animations cannot relocate a newer capture. (4 October 2026)

Real physical Fn is now confirmed by AppKit global press, Gemini start/stop and clipboard logs in Chrome at 10:20:30/10:20:40 and Codex at 10:22:31/10:22:35. Both sequences run with appActive=false. (4 October 2026)

## 4 October 2026: AppKit Fn monitoring replaces the disabled Quartz tap

Version 3.5 build 8 removes the Quartz event tap. The running app measured accessibility=true but quartzListenAccess=false; the previous listener repeatedly stayed disabled despite four re-enable attempts per second. The old started=true log therefore did not prove effective global listening. (4 October 2026)

Permanent NSEvent global and local monitors now cover other apps and ZenRayDictate respectively, with a shared edge detector and missed-release recovery. Runtime startup confirms local=true, global=true and accessibility=true. The capture window and focus handling remain unchanged. (4 October 2026)

Four Fn tests, including local-to-global transition with duplicate down events, pass together with ten library tests and signed bundle verification. Physical Fn from Codex is being verified with the user; monitor installation alone is not proof of keyboard delivery. Apple documents both monitors as necessary for coverage of own and other applications: https://developer.apple.com/library/archive/documentation/Cocoa/Conceptual/EventOverview/MonitoringEvents/MonitoringEvents.html (4 October 2026)

## 4 October 2026: Permanent Fn recovery across focus changes

Version 3.4 build 7 retains a global Fn event tap while the app runs. A 250 ms health check in the common run-loop modes re-enables disabled taps, replaces invalid taps and clears a pressed state when a release was missed. Only physical Fn modifier events trigger capture; checking health never invents a press. Press events and listener recovery are recorded in ~/Library/Logs/ZenRayDictate.log. (4 October 2026)

The Gemini web view uses the public inactiveSchedulingPolicy.none setting so its capture observers and completion timers continue running while inactive. Recording remains visible at right; final text is copied and shown bottom center, then outside-click fade is enabled. (4 October 2026)

Three Fn state tests reproduce a missed-release lock, verify recovery, prevent duplicate held-key presses and reject invented presses. The real Gemini witness probe explicitly deactivates the application before starting and again during capture, then verifies Fn start/stop, visible native waveform and automatic clipboard completion with appActive=false. (4 October 2026)

## 4 October 2026: Visible recording and bottom-center result

Version 3.3 build 6 supersedes the hidden-recording behavior below. Fn starts capture with the real Gemini capsule and native waveform visible at the right edge (340 points wide). The capsule stays visible throughout recording and finalization, even when another application is clicked. Releasing Fn keeps capture active; the next Fn activation stops it. (4 October 2026)

After Gemini finishes, the text is copied automatically and remains visible in a 720-point capsule at the bottom center, 24 points above the available screen edge. Clicking outside fades this completed result away. Idle startup remains hidden; the icon opens the preview. (4 October 2026)

## 4 October 2026: Hidden Fn toggle and automatic clipboard

Version 3.2 starts with the Gemini composer hidden. Press Fn once to start the website microphone and once again to stop; releasing Fn keeps recording. Completed dictation is copied automatically to the clipboard and saved in history without retaining audio. Each capture waits for Gemini's final text before copying. Cancellation copies nothing. (4 October 2026)

Left-click the menu-bar icon to open or hide the real Gemini capsule. The preview is 340 points wide, vertically centered at the right edge, with automatic height up to 460 points. Clicking outside fades it away in 0.18 seconds while an active capture continues invisibly. Right-click the icon for settings and the full Google session. Control+D also toggles capture; Control+Q cancels. This section replaces the historical hold-to-talk instructions below for direct Gemini dictation. (4 October 2026)

The native Gemini waveform and built-in MacBook microphone lock remain in use. Whisper, Parakeet and local-only workflows retain their native route. No benchmark is performed. (4 October 2026)

Verification: `node Scripts/VerifyComposerCapture.mjs` checks delayed final text, exactly one completion, separate captures, unchanged drafts, busy requests and cancellation. `Scripts/VerifyFnCapture.swift` exercises the production Fn handlers against real Gemini with synthetic witness audio in a debug verification bundle. Its proof confirms hidden capture, release remaining active, second activation stopping, clipboard completion, right positioning and fade. The physical Fn key itself still requires a keyboard check. (4 October 2026)

## 3 October 2026: Direct Gemini capsule

The default window now contains Gemini's actual `input-container` DOM, with the website's live microphone. The signed 3.1 app uses a transparent borderless panel, 720 points wide, whose height follows the composer. Its legal footer is hidden in compact mode; the full Gemini session remains available from the menu. (3 October 2026)

The input is pinned to the built-in MacBook microphone by CoreAudio at startup and on default-input changes. AirPods remain available as output. The web media constraints discard old AirPods input IDs, prefer the named built-in input and otherwise use the pinned system default. (3 October 2026)

The native Gemini recording animation stays inside the original composer DOM. No copied waveform, second MediaStream, canvas or audio analyser is added. Its appearance depends on Gemini's recording state and existing draft. (3 October 2026)

Hold Fn for the website microphone; double Fn or Fn+Space keeps it running; Control+D and Command+D toggle it. Control+Q stops and hides the capsule. Drafts remain editable in Gemini. Native history/import/custom modes/Command Mode remain available through the library and advanced native composer; direct Gemini editing does not automatically run that native processing pipeline. Whisper fallback is off by default and has been disabled in the current library. (3 October 2026)

# ZenRay Dictate with Gemini (3 October 2026)

The backend is the Gemini website at gemini.google.com, running in a dedicated app session. The native 18 px composer remains available. No Codex login or paid Gemini API key is required. (3 October 2026)

Hold Fn to dictate and release to transcribe and paste into the active field. Double Fn or Fn+Space enables hands-free; Control+D toggles it. Hold Control+Shift+D to speak a command for the selected text, or generate at the cursor. Command+D retains the original composer recording cycle, and Control+Q cancels. Fn can still show/hide the composer when Hold Fn to dictate is disabled. (3 October 2026)

Open Library, History and Settings from the app or menu bar. Record a custom shortcut, choose the engine and mode, edit custom prompts and per-app rules, import dictionary CSV, add replacements and snippets, correct history entries, or import/drop audio and video. History replay selects its own mode without changing the active one. (3 October 2026)

Gemini supplies transcription and cloud text processing. Installed Whisper and Parakeet are optional local engines; the 100% local switch skips Gemini, including cloud formatting. Local-only mode applies vocabulary, replacements and snippets but does not run a local language model for prompts. Quiet-audio mode boosts capture gain. Screen context reads the focused accessible window and field for spelling, not a screenshot. (3 October 2026)

Successful audio is discarded by default. Opt into Keep audio for later re-transcription; otherwise history can reformat its saved raw text. Failed recordings persist for retry. Settings, modes, vocabulary and history live in ~/Library/Application Support/ZenRayDictate/Library/Library.json. Audio and Pending are below that same folder. Authentication remains in WebKit's separate app profile. (3 October 2026)

Build with ./build.sh, then open ZenRayDictate.app. Grant microphone and Accessibility permissions when macOS asks. Set the macOS globe-key action to Do Nothing yourself to avoid conflicting system actions. Open Gemini session / Sign in if the site requires an account, and select the model whose visible name matches settings. (3 October 2026)

Ten library tests, bridge failure checks and signed bundle checks are reproducible using swift test, node Scripts/VerifyGeminiBridge.mjs, and bash Scripts/verify-independent-composer.sh. [Transport notes and functional probe](Scripts/README-Gemini.md) describe the verified website connection. (3 October 2026)

The documentation below is the historical V2 state; the Gemini section above governs the current backend and controls. (3 October 2026)

# ZenRay Dictate V2

V2 released on 2026-09-12. The empty editor no longer overlays a placeholder label, so the insertion bar remains fully visible and cannot cut through the first character.

![ZenRay Dictate V2 component](docs/v2-component.jpg)

[Read the complete V2 patch notes](docs/patch-notes-v2.md).

ZenRay Dictate is a separate macOS app that recreates the useful Codex composer interaction in an independent native window. The installed Codex chat remains its own app and is never embedded or controlled by this project.

The window keeps one editable prompt area at the top and one recording bar at the bottom. While recording, it shows only the waveform. When recording stops, the app sends the saved WAV to the Codex transcription endpoint, inserts the returned text into the prompt area, and copies the complete prompt to the clipboard.

If the Codex request fails, the installed local Whisper MLX engine is tried. If both paths fail, `last-recording.wav` stays in Application Support and the Retry action uses that exact recording again.

## Controls

- `Control+D` or the legacy `Command+D` starts or stops dictation.
- `Control+Q` cancels the current recording without changing the prompt.
- Clicking outside the composer fades it out.
- `Fn` shows or hides the composer.
- `Command+Q` clears the complete composer text.
- `Command+X` copies the complete composer text, then clears it.
- `Command+C` copies the selected text.
- `Command+V` pastes plain text into the composer.
- The `x` button clears the prompt when idle and cancels recording while recording.
- The circular microphone button starts a new recording after a failed transcription. The menu bar can retry the last saved recording.
- The menu bar item can show, copy, paste, clear, or retry the composer and its last copy.

The composer keeps a fixed `860 x 140` point frame and opens at the bottom center of the active screen, above the Dock area. Long prompt text wraps inside the editor and scrolls there instead of resizing the window.

The UI and flow are an independent reimplementation based on the visible Codex composer behavior. No Codex or ChatGPT source code is bundled.

## Setup

Requires macOS 14+, the existing Codex login in `~/.codex/auth.json`, and the local ASR environment at `~/.venvs/asr-ja`.

```bash
./make-certificate.sh
./build.sh
open ZenRayDictate.app
```

The first recording asks for microphone access. The Fn control asks for Accessibility access when macOS has not granted it yet.

## Project layout

| File | Role |
|---|---|
| `main.swift` | App entry point |
| `AppDelegate.swift` | Window lifecycle, menu bar, and global shortcuts |
| `ComposerWindowController.swift` | Independent Codex-style composer and retry state |
| `AudioCapture.swift` | WAV capture and waveform levels |
| `Transcriber.swift` | Codex endpoint, local Whisper fallback, and response validation |
| `GlobalHotKey.swift` | System-wide Control+D, legacy Command+D, and Control+Q shortcuts |
| `FnKeyMonitor.swift` | System-wide Fn visibility control |
| `Log.swift` | Log at `~/Library/Logs/ZenRayDictate.log` |
| `Entitlements.plist` | Audio input entitlement |
| `Scripts/verify-independent-composer.sh` | Repeatable build and bundle checks |

## License

MIT. See [LICENSE](LICENSE).
