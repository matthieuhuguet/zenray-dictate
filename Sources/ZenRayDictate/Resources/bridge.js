// Injected into chatgpt.com at document end.
//
// It does not rebuild the dictation request. It drives the page's own dictation
// controls and listens to the response of POST /backend-api/transcribe, whose
// body is {"text": "...", "asset_pointer": "...", "asset_format": "webm"}.
// The page keeps doing the recording, the encoding and the upload itself.
//
// Buttons are matched by PATTERN, never by an exact label. The stop control has
// been seen as both "Submit dictation" and "Stop dictation" depending on the
// build being served, and hard coding one of them made the app believe dictation
// had vanished while it was in fact running.

(() => {
  if (window.__zrInstalled) return;
  window.__zrInstalled = true;

  const send = (type, payload) => {
    try {
      window.webkit.messageHandlers.zenray.postMessage({ type: type, payload: payload });
    } catch (e) {}
  };

  // --- observe the transcription response -----------------------------------

  const originalFetch = window.fetch;
  window.fetch = function (input, init) {
    const url = typeof input === 'string' ? input : (input && input.url) || '';
    const promise = originalFetch.apply(this, arguments);
    if (/\/backend-api\/transcribe/.test(url)) {
      promise
        .then(async (res) => {
          try {
            const data = await res.clone().json();
            send('transcript', (data && data.text) || '');
          } catch (e) {
            send('error', 'Unreadable response from ChatGPT.');
          }
        })
        .catch(() => send('error', 'The transcription request failed.'));
    }
    return promise;
  };

  // --- finding the controls -------------------------------------------------

  const match = (re) =>
    [...document.querySelectorAll('button')].find((b) =>
      re.test(b.getAttribute('aria-label') || '')
    );

  const startButton  = () => match(/start\s+dictation|begin\s+dictation/i);
  const stopButton   = () => match(/(stop|submit|finish|end|done)\s+dictation/i);
  const cancelButton = () => match(/cancel\s+dictation/i);

  const isDictating = () => !!stopButton() || !!cancelButton();

  const micBlocked = () =>
    /enable mic access/i.test(document.body ? document.body.innerText : '');

  const clearComposer = () => {
    const box = document.querySelector('#prompt-textarea, div[contenteditable="true"]');
    if (!box) return;
    box.innerHTML = '<p><br></p>';
    box.dispatchEvent(new InputEvent('input', { bubbles: true }));
  };

  const waitFor = (test, timeout) =>
    new Promise((resolve) => {
      const started = Date.now();
      const tick = () => {
        if (test()) return resolve(true);
        if (Date.now() - started > timeout) return resolve(false);
        setTimeout(tick, 100);
      };
      tick();
    });

  // --- controls -------------------------------------------------------------

  window.__zrReady = () => !!startButton();

  window.__zrStart = () => {
    // Already running, for instance because it was started by hand on the page.
    if (isDictating()) {
      send('recording', '');
      return 'already';
    }
    if (micBlocked()) {
      send('mic-blocked', '');
      return 'mic-blocked';
    }
    const b = startButton();
    if (!b) {
      send('start-failed', 'The dictation button is not on the page.');
      return 'no-button';
    }
    clearComposer();
    b.click();

    // Confirm against the page rather than assume. No second click here: while
    // dictation is running the start control is gone, so clicking again would
    // only fight the state we just created.
    waitFor(isDictating, 6000).then((ok) => {
      if (ok) return send('recording', '');
      if (micBlocked()) return send('mic-blocked', '');
      send('start-failed', 'ChatGPT refused to start dictating.');
    });
    return 'starting';
  };

  window.__zrStop = () => {
    const b = stopButton();
    if (!b) {
      send('start-failed', 'Dictation was not running.');
      return 'not-recording';
    }
    b.click();
    return 'transcribing';
  };

  window.__zrCancel = () => {
    const c = cancelButton();
    if (c) c.click();
    clearComposer();
    return 'cancelled';
  };

  window.__zrCleanup = () => {
    clearComposer();
    return 'clean';
  };

  /// Everything worth knowing when a refusal has to be diagnosed.
  window.__zrDiagnose = () =>
    JSON.stringify({
      url: location.href,
      visibility: document.visibilityState,
      micBanner: micBlocked(),
      dictating: isDictating(),
      labels: [...document.querySelectorAll('button')]
        .map((b) => b.getAttribute('aria-label'))
        .filter((l) => l && /dicta/i.test(l))
    });

  // --- readiness ------------------------------------------------------------

  const poll = setInterval(() => {
    if (window.__zrReady()) {
      clearInterval(poll);
      send('ready', location.href);
    }
  }, 400);
  setTimeout(() => clearInterval(poll), 120000);
})();
