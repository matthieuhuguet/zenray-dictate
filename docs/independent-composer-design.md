# Independent Composer Design

## Goal

Keep Codex chat and ZenRay Dictate open at the same time, while giving ZenRay Dictate its own native composer instance with the same useful interaction: editable text above, recording waveform below, live preview during speech, and a final transcription inserted into the composer.

## Observed Codex behavior

The Codex composer records locally, keeps the recording while the transcription request is pending, exposes a stop state, and allows a failed recording to be retried. Its final transcription request is a multipart upload to `/backend-api/transcribe`.

ZenRay Dictate reimplements that contract in Swift and does not copy bundled Codex source or assets.

## Failure contract

The WAV is copied to `~/Library/Application Support/ZenRayDictate/Pending/last-recording.wav` before every transcription attempt. A successful transcription clears that file. A failed attempt leaves it in place and changes the UI to `Saved for retry`.

## Acceptance criteria

1. The app opens one visible rectangular composer without opening or manipulating the Codex window.
2. Control+D starts and stops the independent audio capture.
3. Control+Q cancels the capture and preserves the current prompt.
4. A successful Codex response is inserted into the prompt area.
5. A failed response leaves a durable recording and Retry uses it after relaunch.
6. The release bundle links AVFoundation and Speech, includes microphone usage text, and contains no WebKit bridge.
