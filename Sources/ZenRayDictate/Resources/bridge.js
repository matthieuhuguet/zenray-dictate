// Injected into chatgpt.com at document start.
//
// It does not rebuild the dictation request. It clicks the page's own dictation
// controls and listens to the response of POST /backend-api/transcribe, whose
// body is {"text": "...", "asset_pointer": "...", "asset_format": "webm"}.
// The page keeps doing the recording, the encoding and the upload itself.

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
            send('error', 'unreadable response: ' + e);
          }
        })
        .catch((e) => send('error', 'request failed: ' + e));
    }
    return promise;
  };

  // --- controls -------------------------------------------------------------

  const button = (label) =>
    [...document.querySelectorAll('button')].find(
      (b) => (b.getAttribute('aria-label') || '') === label
    );

  // The composer is a ProseMirror contenteditable. Emptying it stops the
  // dictated text from lingering in the page, and stops any auto-submit from
  // having anything to send.
  const clearComposer = () => {
    const box = document.querySelector('#prompt-textarea, div[contenteditable="true"]');
    if (!box) return;
    box.innerHTML = '<p><br></p>';
    box.dispatchEvent(new InputEvent('input', { bubbles: true }));
  };

  window.__zrReady = () => !!button('Start dictation');

  window.__zrStart = () => {
    const b = button('Start dictation');
    if (!b) return 'not-ready';
    clearComposer();
    b.click();
    return 'recording';
  };

  window.__zrStop = () => {
    const b = button('Submit dictation');
    if (!b) return 'not-recording';
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

  // Tell the app once the composer exists, so it knows the session is live.
  const poll = setInterval(() => {
    if (window.__zrReady()) {
      clearInterval(poll);
      send('ready', location.href);
    }
  }, 500);
  setTimeout(() => clearInterval(poll), 60000);
})();
