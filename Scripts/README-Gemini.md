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
