// Injected into chatgpt.com.
//
// Does nothing but watch. You click Start Dictation and Stop Dictation
// yourself, on the real page. This script only listens to the response of
// POST /backend-api/transcribe, whose body is
// {"text": "...", "asset_pointer": "...", "asset_format": "webm"}, and hands
// the text to Swift so it can be copied to the clipboard.

(() => {
  if (window.__zrInstalled) return;
  window.__zrInstalled = true;

  const send = (type, payload) => {
    try {
      window.webkit.messageHandlers.zenray.postMessage({ type, payload });
    } catch (e) {}
  };

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

  send('ready', location.href);
})();
