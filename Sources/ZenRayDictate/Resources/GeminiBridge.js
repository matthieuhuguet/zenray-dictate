// 3 October 2026, 15:52 CEST: replay saved WAV through Gemini's microphone without submitting a chat.
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
      // 3 October 2026, 21:57 CEST: ignore cached AirPods IDs; native CoreAudio pins the built-in default input.
      if (!constraints?.audio || constraints.video) return originalCapture(constraints);
      const {deviceId,groupId,...audio} = typeof constraints.audio === 'object' ? constraints.audio : {};
      const devices = await navigator.mediaDevices.enumerateDevices?.() || [];
      const builtin = devices.find(device => device.kind === 'audioinput' && /MacBook|built[ -]?in|microphone interne/i.test(device.label));
      if (builtin) audio.deviceId = {exact:builtin.deviceId};
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
