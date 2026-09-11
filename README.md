# ZenRay Dictate

A small macOS menu bar helper for the native Codex composer. `Cmd+D` starts or
stops Codex dictation, and the complete composer text is copied after Stop.

## How it works

ZenRay Dictate does not implement a second composer. Codex owns the single
visible interface, including the text area,
live transcription, microphone, waveform, and native retry state.

ZenRay Dictate uses macOS Accessibility to:

1. Bring Codex to the front and focus its composer.
2. Press the native `Dictate` control on `Cmd+D`.
3. Press Codex's native `Stop dictation` control on the next `Cmd+D`.
4. Read the finished composer and copy the complete text to the clipboard.
5. Keep a failed clipboard result in memory for `Retry last copy`.

The helper never sends a prompt. It only controls the composer and leaves the
native Codex interface in charge of recording and transcription.

## Setup

Requires macOS 14+, the installed Codex desktop app, microphone access granted
to Codex, and Accessibility access granted to ZenRay Dictate.

```bash
./make-certificate.sh
./build.sh
open ZenRayDictate.app
```

Press `Cmd+D` anywhere to start or stop dictation in Codex. Press `Fn` to show
or hide Codex. Use the menu bar item to clear, copy, or retry the composer.

## Project layout

| File | Role |
|---|---|
| `main.swift` | Entry point |
| `AppDelegate.swift` | Menu bar, shortcuts, and lifecycle |
| `CodexController.swift` | Native Codex Accessibility controller and clipboard flow |
| `GlobalHotKey.swift` | System-wide `Cmd+D` shortcut |
| `FnKeyMonitor.swift` | System-wide `Fn` monitor |
| `AudioInput.swift` | Preferred system input device selection |
| `Permissions.swift` | Accessibility permission helpers |
| `Log.swift` | Log at `~/Library/Logs/ZenRayDictate.log` |
| `Entitlements.plist` | Hardened runtime entitlements |

## License

MIT. See [LICENSE](LICENSE).
