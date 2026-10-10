// 3 October 2026, 15:52 CEST: replay saved WAV through Gemini's microphone without submitting a chat.
// 10 October 2026: stream live 16 kHz PCM16 audio from NativeMicrophoneBridge (input-only AUHAL) into
// WebAudio MediaStreamDestination so WebKit never instantiates VPIO / AUVPAggregate on AirPods Pro output.
(() => {
  if (location.hostname !== 'gemini.google.com') return;
  const settings = {
    editorSelector: '[role="textbox"][contenteditable="true"]',
    microphoneLabels: /^(Dicter|Dictate|Use microphone|Microphone)(?:\s|$)/i,
    stopLabels: /^(Arrêter|Stop|Terminer|Done)(?:\s|$)/i,
    settleMs: 2000,
    pollMs: 150,
    captureTimeoutMs: 12000,
  };
  let active = null;
  let liveStreamState = null;
  const stopLiveNativeStream = () => {
    if (!liveStreamState) return;
    const current = liveStreamState;
    liveStreamState = null;
    current.active = false;
    try { window.webkit?.messageHandlers?.nativeMic?.postMessage({ action: 'stop' }); } catch {}
    if (current.context) current.context.close().catch(() => {});
  };
  window.ZenRayNativeMic = {
    isActive: () => Boolean(liveStreamState && liveStreamState.active),
    chunksReceived: () => liveStreamState?.chunksReceived || 0,
    stop: stopLiveNativeStream,
    pushPCM16: (base64, sampleRate = 16000) => {
      if (!liveStreamState || !liveStreamState.active) return;
      const { context, destination } = liveStreamState;
      if (context.state === 'suspended') context.resume().catch(() => {});
      const binary = atob(base64);
      const len = binary.length >> 1;
      if (len <= 0) return;
      const audioBuffer = context.createBuffer(1, len, sampleRate);
      const channel = audioBuffer.getChannelData(0);
      for (let i = 0; i < len; i++) {
        const lo = binary.charCodeAt(i * 2);
        const hi = binary.charCodeAt(i * 2 + 1);
        let val = (hi << 8) | lo;
        if (val >= 0x8000) val -= 0x10000;
        channel[i] = val / 32768.0;
      }
      const source = context.createBufferSource();
      source.buffer = audioBuffer;
      source.connect(destination);
      const now = context.currentTime;
      if (liveStreamState.nextStartTime < now) {
        liveStreamState.nextStartTime = now + 0.015;
      }
      source.start(liveStreamState.nextStartTime);
      liveStreamState.nextStartTime += audioBuffer.duration;
      liveStreamState.chunksReceived = (liveStreamState.chunksReceived || 0) + 1;
    },
  };
  const editor = () => document.querySelector(settings.editorSelector);
  const button = pattern => [...document.querySelectorAll('button[aria-label]')]
    .find(el => !el.disabled && el.getClientRects().length && pattern.test(el.getAttribute('aria-label')));
  const sleep = ms => new Promise(resolve => setTimeout(resolve, ms));
  const report = (request, payload) => window.webkit.messageHandlers.dictation.postMessage({ id: request.id, ...payload });
  const clean = async request => {
    request.cancelled = true;
    if (request.source) { try { request.source.stop(); } catch {} }
    request.stream?.getTracks().forEach(track => track.stop());
    if (request.context) await request.context.close().catch(() => {});
    if (active === request) active = null;
  };
  const originalCapture = navigator.mediaDevices?.getUserMedia?.bind(navigator.mediaDevices);
  if (originalCapture) navigator.mediaDevices.getUserMedia = async constraints => {
    const request = active;
    if (!request) {
      if (!constraints?.audio || constraints.video) return originalCapture(constraints);
      // 10 October 2026: route live microphone capture through NativeMicrophoneBridge (input-only AUHAL)
      // when running in the native WKWebView session, bypassing WebKit's VPIO / AUVPAggregate state fault.
      if (window.webkit?.messageHandlers?.nativeMic && !window.ZenRayVerificationAudio) {
        stopLiveNativeStream();
        const context = new AudioContext();
        const destination = context.createMediaStreamDestination();
        const keepalive = context.createGain();
        keepalive.gain.value = 0;
        keepalive.connect(destination);
        liveStreamState = { context, destination, nextStartTime: 0, active: true, chunksReceived: 0 };
        const stream = destination.stream;
        stream.getTracks().forEach(track => {
          const origStop = track.stop.bind(track);
          track.stop = () => {
            stopLiveNativeStream();
            return origStop();
          };
          track.applyConstraints = async () => {};
        });
        await context.resume();
        window.webkit.messageHandlers.nativeMic.postMessage({ action: 'start' });
        return stream;
      }
      // 6 October 2026, 12:42 CEST: use the system microphone without retaining a cached device ID.
      const {deviceId,groupId,...audio} = typeof constraints.audio === 'object' ? constraints.audio : {};
      return originalCapture({...constraints,audio});
    }
    if (!constraints?.audio || constraints.video) throw new Error('Only saved audio dictation is supported.');
    if (request.stream) return request.stream;
    const context = request.context;
    const destination = context.createMediaStreamDestination();
    const source = context.createBufferSource();
    source.buffer = request.buffer;
    source.connect(destination);
    request.stream = destination.stream;
    request.source = source;
    source.onended = () => { request.endedAt = Date.now(); };
    await context.resume();
    request.startedAt = Date.now();
    source.start(context.currentTime + 0.25);
    return request.stream;
  };
  window.ZenRayGemini = {
    isBusy: () => Boolean(active),
    ready: () => Boolean(editor() && button(settings.microphoneLabels) && originalCapture),
    cancel: async () => {
      stopLiveNativeStream();
      if (!active) return;
      const request = active;
      if (request.startedAt && !request.stopped) button(settings.stopLabels)?.click();
      if (request.kind === "rewrite") button(/^(Arrêter la réponse|Stop response|Stop generating)/i)?.click();
      await clean(request);
    },
    rewrite: async payload => {
      if (active) throw new Error('Gemini is busy.');
      const request = { id: payload.id, cancelled: false, kind: "rewrite" };
      active = request;
      const responses = () => [...document.querySelectorAll('message-content .markdown')];
      try {
        const field = editor();
        if (!field || field.innerText.trim()) throw new Error('Gemini contains a draft. Clear the dedicated session before processing text.');
        const before = responses().length;
        const picker = document.querySelector('[data-test-id="bard-mode-menu-button"]');
        if (picker && payload.model && !picker.innerText.includes(payload.model)) throw new Error('Choose ' + payload.model + ' in the Gemini session before processing this mode.');
        field.focus();
        document.execCommand('insertText', false, payload.instruction + '\n\nInput:\n' + payload.text);
        let send;
        for (let attempt = 0; attempt < 40 && !send; attempt++) {
          await sleep(settings.pollMs);
          send = button(/^(Envoyer|Send|Submit)(?:\s|$)/i);
        }
        if (!send) throw new Error('Gemini Send control is unavailable.');
        send.click();
        const deadline = Date.now() + 85000;
        let last = '', changedAt = Date.now();
        while (!request.cancelled && Date.now() < deadline) {
          const list = responses();
          const response = list.length > before ? list[list.length - 1] : null;
          const text = response ? (response.innerText || response.textContent || '').trim() : ''; 
          if (text !== last) { last = text; changedAt = Date.now(); }
          const generating = button(/^(Arrêter la réponse|Stop response|Stop generating)/i);
          if (last && !generating && Date.now() - changedAt > settings.settleMs) {
            await clean(request); report(request, { text: last }); return;
          }
          await sleep(settings.pollMs);
        }
        if (!request.cancelled) throw new Error('Gemini did not complete its text response.');
      } catch (error) { const notify = !request.cancelled; await clean(request); if (notify) report(request, { error: error.message }); }
      finally { await clean(request); }
    },
    transcribe: async payload => {
      if (active) throw new Error('Gemini dictation is busy.');
      const request = { id: payload.id, cancelled: false };
      active = request;
      try {
        const field = editor();
        const microphone = button(settings.microphoneLabels);
        if (!field || !microphone) throw new Error('Gemini microphone is unavailable. Sign in and retry.');
        if (field.innerText.trim()) throw new Error('Clear the draft in the dedicated Gemini session before retrying.');
        const bytes = Uint8Array.from(atob(payload.audio), character => character.charCodeAt(0));
        request.context = new AudioContext();
        request.buffer = await request.context.decodeAudioData(bytes.buffer);
        const started = Date.now();
        microphone.click();
        while (!request.startedAt && !request.cancelled && Date.now() - started < settings.captureTimeoutMs) await sleep(settings.pollMs);
        if (!request.startedAt) throw new Error('Gemini did not request saved microphone audio. Check session permissions and retry.');
        const deadline = started + request.buffer.duration * 1000 + payload.responseTimeoutMs;
        let lastText = '', changedAt = Date.now();
        while (!request.cancelled && Date.now() < deadline) {
          const text = editor()?.innerText.trim() || '';
          if (text !== lastText) { lastText = text; changedAt = Date.now(); }
          if (request.endedAt && !request.stopped && Date.now() - request.endedAt >= 400) {
            const stop = button(settings.stopLabels);
            if (stop) stop.click();
            request.stopped = true;
          }
          if (request.endedAt && request.stopped && lastText && Date.now() - Math.max(changedAt, request.endedAt) >= settings.settleMs && button(settings.microphoneLabels)) {
            await clean(request);
            // 3 October 2026, 15:52 CEST: clear only our completed transcript, never an unrelated draft.
            if (editor()?.innerText.trim() === lastText) {
              const selection = getSelection();
              const range = document.createRange();
              range.selectNodeContents(editor());
              selection.removeAllRanges(); selection.addRange(range);
              document.execCommand('delete');
            }
            report(request, { text: lastText });
            return;
          }
          await sleep(settings.pollMs);
        }
        if (!request.cancelled) throw new Error('Gemini returned no completed transcript; saved recording is available for retry.');
      } catch (error) {
        const notify = !request.cancelled; await clean(request); if (notify) report(request, { error: error.message });
      } finally { await clean(request); }
    },
  };
})();
