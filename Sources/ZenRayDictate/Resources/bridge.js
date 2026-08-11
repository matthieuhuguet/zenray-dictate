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

  // --- compact mode ---------------------------------------------------------
  //
  // Strips the page down to the composer alone, so the app can float the real
  // ChatGPT bar instead of imitating it. Everything that is not an ancestor of
  // the composer is hidden, the ancestors are flattened to transparent full
  // width boxes, and the page background is made see through. Leaving compact
  // mode is done by reloading, which is far cheaper than restoring by hand.

  window.__zrCompact = () => {
    const anchor =
      document.querySelector('#prompt-textarea') ||
      document.querySelector('div[contenteditable="true"]');
    if (!anchor) return 'no-composer';

    const target = anchor.closest('form') || anchor.parentElement;

    const chain = [];
    for (let n = target; n && n !== document.documentElement; n = n.parentElement) {
      chain.push(n);
    }
    const inChain = new Set(chain);

    chain.forEach((n) => {
      const parent = n.parentElement;
      if (parent) {
        [...parent.children].forEach((sib) => {
          if (!inChain.has(sib)) sib.style.display = 'none';
        });
      }
      n.style.setProperty('position', 'static', 'important');
      n.style.setProperty('margin', '0', 'important');
      n.style.setProperty('padding', '0', 'important');
      n.style.setProperty('max-width', 'none', 'important');
      n.style.setProperty('width', '100%', 'important');
      n.style.setProperty('height', 'auto', 'important');
      n.style.setProperty('min-height', '0', 'important');
      n.style.setProperty('background', 'transparent', 'important');
      n.style.setProperty('border', 'none', 'important');
      n.style.setProperty('box-shadow', 'none', 'important');
      n.style.setProperty('transform', 'none', 'important');
      n.style.setProperty('inset', 'auto', 'important');
    });

    if (!document.getElementById('zr-compact-style')) {
      const style = document.createElement('style');
      style.id = 'zr-compact-style';
      style.textContent = `
        html, body {
          background: transparent !important;
          margin: 0 !important; padding: 0 !important;
          overflow: hidden !important; height: auto !important;
        }
        ::-webkit-scrollbar { display: none !important; }
        [data-testid="composer-footer-actions"] { display: none !important; }
      `;
      document.head.appendChild(style);
    }

    // Layout settles a frame or two later, so measure after it has.
    setTimeout(() => {
      const r = target.getBoundingClientRect();
      send('compact', JSON.stringify({
        width: Math.ceil(r.width),
        height: Math.ceil(r.height)
      }));
    }, 250);

    return 'compacted';
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
