# Independent Composer Design

## Goal

Keep Codex chat and ZenRay Dictate open at the same time, while giving ZenRay Dictate its own native composer instance with the same useful interaction: one editable text area above, a recording waveform below, and a final transcription inserted into the composer.

## Observed Codex behavior

The Codex composer records locally, keeps the recording while the transcription request is pending, exposes a stop state, and allows a failed recording to be retried. Its final transcription request is a multipart upload to `/backend-api/transcribe`.

ZenRay Dictate reimplements that contract in Swift and does not copy bundled Codex source or assets.

## Restored controls

The independent composer keeps only the useful controls from the former interface: clicking outside fades it out, Fn shows or hides it, Control+D or legacy Command+D starts or stops dictation and reveals the composer when needed, Control+Q cancels the current recording, the x button clears idle text or cancels a recording, Command+Q clears the complete prompt, and Command+X copies then clears the complete prompt. Command+C and Command+V explicitly copy and paste plain text in the editor.

The window stays fixed at `860 x 360` points. The prompt editor wraps long text and scrolls inside its own area, so speaking or writing more never changes the panel geometry. The former live transcript field is removed because it could contribute an unbounded intrinsic width.

Both action buttons use equal width and height constraints, a circular corner curve, and a masked layer so their backgrounds remain perfect circles after layout.

## Failure contract

The WAV is copied to `~/Library/Application Support/ZenRayDictate/Pending/last-recording.wav` before every transcription attempt. A successful transcription clears that file. A failed attempt leaves it in place and changes the UI to `Saved for retry`.

## Acceptance criteria

1. The app opens one visible rectangular composer without opening or manipulating the Codex window.
2. Control+D starts and stops the independent audio capture.
3. Control+Q cancels the capture and preserves the current prompt.
4. A successful Codex response is inserted into the prompt area.
5. A failed response leaves a durable recording and Retry uses it after relaunch.
6. The release bundle links AVFoundation, includes microphone usage text, and contains no Speech or WebKit bridge.
7. Clicking outside fades the composer out and Fn toggles visibility.
8. The fixed window keeps its size while long prompt text wraps and scrolls inside the editor.
9. Command+Q clears the prompt, Command+X copies then clears it, and Command+V pastes plain text.
10. A successful transcription is automatically copied to the clipboard, with an in-memory retry action if the pasteboard rejects it.
