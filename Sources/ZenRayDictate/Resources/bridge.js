// Injected into chatgpt.com at document end.
//
// It does not rebuild the dictation request. It clicks the page's own dictation
// controls and listens to the response of POST /backend-api/transcribe, whose
// body is {"text": "...", "asset_pointer": "...", "asset_format": "webm"}.
// The page keeps doing the recording, the encoding and the upload itself.
//
// Every state change is confirmed against the DOM before it is reported, so the
// app never sits in a state the page is not actually in.

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

  // --- helpers --------------------------------------------------------------

  const button = (label) =>
    [...document.querySelectorAll('button')].find(
      (b) => (b.getAttribute('aria-label') || '') === label
    );

  // ChatGPT shows a red banner when the browser refused the microphone.
  const micBlocked = () =>
    /enable mic access/i.test(document.body ? document.body.innerText : '');

  const clearComposer = () => {
    const box = document.querySelector('#prompt-textarea, div[contenteditable="true"]');
    if (!box) return;
    box.innerHTML = '<p><br></p>';
    box.dispatchEvent(new InputEvent('input', { bubbles: true }));
  };

  // Waits for a condition, then resolves true, or false on timeout.
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

  window.__zrReady = () => !!button('Start dictation');

  window.__zrStart = () => {
    if (micBlocked()) {
      send('mic-blocked', '');
      return 'mic-blocked';
    }
    const b = button('Start dictation');
    if (!b) {
      send('start-failed', 'The dictation button is not on the page.');
      return 'no-button';
    }
    clearComposer();
    b.click();

    // Confirm the page really entered dictation mode. Granting the microphone
    // and spinning up the recorder can take a moment on a cold page, hence the
    // generous window, and one retry before giving up.
    waitFor(() => !!button('Submit dictation'), 4000).then((ok) => {
      if (ok) return send('recording', '');
      if (micBlocked()) return send('mic-blocked', '');

      const again = button('Start dictation');
      if (!again) {
        return send('start-failed', 'Dictation controls vanished from the page.');
      }
      again.click();
      waitFor(() => !!button('Submit dictation'), 4000).then((ok2) => {
        if (ok2) return send('recording', '');
        if (micBlocked()) return send('mic-blocked', '');
        send('start-failed', 'ChatGPT refused to start dictating.');
      });
    });
    return 'starting';
  };

  /// What the page looks like right now, for diagnosing a refusal.
  window.__zrDiagnose = () =>
    JSON.stringify({
      url: location.href,
      visibility: document.visibilityState,
      micBanner: micBlocked(),
      start: !!button('Start dictation'),
      submit: !!button('Submit dictation'),
      cancel: !!button('Cancel dictation')
    });

  window.__zrStop = () => {
    const b = button('Submit dictation');
    if (!b) {
      send('start-failed', 'Dictation was not running.');
      return 'not-recording';
    }
    b.click();
    return 'transcribing';
  };

  window.__zrCancel = () => {
    const b = button('Cancel dictation');
    if (b) b.click();
    clearComposer();
    return 'cancelled';
  };

  window.__zrCleanup = () => {
    clearComposer();
    return 'clean';
  };

  // --- readiness ------------------------------------------------------------

  const poll = setInterval(() => {
    if (window.__zrReady()) {
      clearInterval(poll);
      send('ready', location.href);
    }
  }, 400);
  setTimeout(() => clearInterval(poll), 120000);
})();
