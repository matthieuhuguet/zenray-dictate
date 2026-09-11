# Independent Composer Design

## Goal

Keep Codex chat and ZenRay Dictate open at the same time, while giving ZenRay Dictate its own native composer instance with the same useful interaction: editable text above, recording waveform below, live preview during speech, and a final transcription inserted into the composer.

## Observed Codex behavior

The Codex composer records locally, keeps the recording while the transcription request is pending, exposes a stop state, and allows a failed recording to be retried. Its final transcription request is a multipart upload to `/backend-api/transcribe`.

ZenRay Dictate reimplements that contract in Swift and does not copy bundled Codex source or assets.

## Restored controls

The independent composer keeps only the useful controls from the former interface: clicking outside or pressing Fn fades it out, Control+D starts or stops dictation and reveals the composer when needed, Control+Q cancels the current recording, Command+Q clears the complete prompt, and Command+X copies then clears the complete prompt.

The window stays fixed at `860 x 360` points. The prompt editor wraps long text and scrolls inside its own area, so speaking or writing more never changes the panel geometry.

## Failure contract

The WAV is copied to `~/Library/Application Support/ZenRayDictate/Pending/last-recording.wav` before every transcription attempt. A successful transcription clears that file. A failed attempt leaves it in place and changes the UI to `Saved for retry`.

## Acceptance criteria

1. The app opens one visible rectangular composer without opening or manipulating the Codex window.
2. Control+D starts and stops the independent audio capture.
3. Control+Q cancels the capture and preserves the current prompt.
4. A successful Codex response is inserted into the prompt area.
5. A failed response leaves a durable recording and Retry uses it after relaunch.
6. The release bundle links AVFoundation and Speech, includes microphone usage text, and contains no WebKit bridge.
7. Clicking outside or pressing Fn fades the composer out.
8. The fixed window keeps its size while long prompt text wraps and scrolls inside the editor.
9. Command+Q clears the prompt and Command+X copies then clears it.
