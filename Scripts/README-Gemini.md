# Gemini website connection (3 October 2026)

The native app runs a dedicated WKWebView session at gemini.google.com. It uses the site's microphone flow by supplying the saved recording through a synthetic audio stream. It reads the transcription from the composer without submitting a conversation. No API key or personal browser profile is used. (3 October 2026)

Cloud formatting and Command Mode submit the dictated text and the chosen instruction to Gemini in that same app session. Optional spelling context is the focused accessible window and field, limited to 6000 characters; this reads accessible labels rather than full-screen OCR. Select the desired Gemini model in the dedicated session and enter its visible name in settings. (3 October 2026)

The site's public code identifies its microphone transport as Google S3 SpeechDictationClient with intelligent-dictation. Gemini 3.5 Transcribe exists in Google's API documentation, but this does not prove that the website uses that model. The app therefore labels the provider Gemini web dictation. (3 October 2026)

## Reproduce functional checks (3 October 2026)

```sh
swift test
node Scripts/VerifyGeminiBridge.mjs
bash Scripts/verify-independent-composer.sh
swiftc Scripts/GeminiSessionProbe.swift -o "$HOME/.claude/tmp/tmp-zenray-dictate/GeminiSessionProbe" -framework AppKit -framework WebKit
"$HOME/.claude/tmp/tmp-zenray-dictate/GeminiSessionProbe" "$HOME/.claude/tmp/tmp-zenray-dictate/GeminiWitness.wav" --flow
```

The flow probe supplies a synthetic witness recording, then formats the returned transcript in the same session. It exits with an error if the site refuses the operation. It never installs a model or performs a speed comparison. (3 October 2026)

The first rewrite probe found no Send button because Quill updates asynchronously; waiting for the enabled control fixes it. Hidden WKWebView responses can have an empty innerText while their markdown textContent is populated, so the bridge reads the latter as a fallback. The completed flow is preserved in GeminiFlowProof.txt in the mapped workshop. (3 October 2026)

## 10 October 2026: Native input-only AUHAL microphone bridge and AirPods Pro verification

Live dictation in `GeminiWebTranscriber` no longer delegates live capture to WebKit's native `navigator.mediaDevices.getUserMedia`, because `com.apple.WebKit.GPU` creates a `VPAUAggregateAudioDevice` (`VoiceProcessingIO`) that combines the input microphone with the `AirPods Pro` Bluetooth output (`2014 4c`), ducks output volume to 17%, and fails with `VoiceProcessor failed to run downlink DSP (state fault)` (`Error code 1937006964 'stft'`). (10 October 2026)

Instead, `NativeMicrophoneBridge.swift` opens a standalone CoreAudio `AUHAL` (`kAudioUnitSubType_HALOutput`) strictly in input-only mode (`enableInput = 1` on bus 1, `disableOutput = 0` on bus 0) on the chosen physical input (`MacBook Pro Microphone` or `iPhone Continuity Microphone`), downsamples `48 000 Hz` mono audio to `16 000 Hz` PCM16 frames (`640` samples per 40 ms), and streams them into `window.ZenRayNativeMic` (`AudioContext.createMediaStreamDestination()`) inside `GeminiBridge.js`. (10 October 2026)

```sh
node Scripts/VerifyGeminiBridge.mjs
swiftc -parse-as-library Sources/ZenRayDictate/Log.swift Sources/ZenRayDictate/BuiltinMicrophone.swift Sources/ZenRayDictate/MicrophoneManager.swift Sources/ZenRayDictate/NativeMicrophoneBridge.swift Scripts/VerifyMicrophoneAndAirPodsFix.swift -o "$HOME/.claude/tmp/tmp-zenray-dictate/VerifyMicrophoneAndAirPodsFix"
"$HOME/.claude/tmp/tmp-zenray-dictate/VerifyMicrophoneAndAirPodsFix"
```

`VerifyMicrophoneAndAirPodsFix` confirms bidirectional selection persistence (`iPhone Microphone` and `MacBook Pro Microphone`), automatic restoration against Bluetooth headset input hijack (`AirPods Pro`, `Sony WH-1000XM3`, `Sony WH-1000XM5`), and live `AUHAL` PCM16 frame delivery on both microphones. `Scripts/VerifyLiveNativeMicGemini.swift` confirms full end-to-end live `AUHAL` dictation through `GeminiWebTranscriber` on both `MacBook Pro Microphone` and `iPhone Microphone` with zero `VoiceProcessor` faults. (10 October 2026)
