// Injected into chatgpt.com.
//
// Two jobs, nothing more:
//
// 1. Watch. Listen to the response of POST /backend-api/transcribe, whose body
//    is {"text": "...", "asset_format": "webm"}, and hand the text to Swift so
//    it can be copied to the clipboard. No button is ever clicked by this
//    script, no button label is ever matched: you click Start Dictation and
//    Stop Dictation yourself, on the real page.
//
// 2. Trim. Strip the page down to the composer bar alone, so the window can be
//    sized to just the capsule instead of the full ChatGPT app around it. This
//    is pure layout: everything that is not an ancestor of the composer is
//    hidden, the ancestors are flattened to transparent full width boxes, and
//    the real composer keeps every one of its own buttons live underneath.

(() => {
  if (window.__zrInstalled) return;
  window.__zrInstalled = true;

  const send = (type, payload) => {
    try {
      window.webkit.messageHandlers.zenray.postMessage({ type, payload });
    } catch (e) {}
  };

  // --- 1. watch the transcription response -----------------------------------

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

  // --- 2. trim the page to the composer bar -----------------------------------

  const PAD = 12;   // margin kept around the pill so its shadow has room

  const compact = () => {
    const anchor =
      document.querySelector('#prompt-textarea') ||
      document.querySelector('div[contenteditable="true"]');
    if (!anchor) return false;

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
          if (!inChain.has(sib)) sib.style.setProperty('display', 'none', 'important');
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
          margin: 0 !important;
          overflow: hidden !important;
          height: auto !important;
        }
        body { padding: ${PAD}px !important; box-sizing: border-box !important; }
        ::-webkit-scrollbar { display: none !important; }
      `;
      document.head.appendChild(style);
    }

    const report = () => {
      const r = target.getBoundingClientRect();
      if (r.height < 20) return;
      send('compact', JSON.stringify({
        width: Math.ceil(r.width) + PAD * 2,
        height: Math.ceil(r.height) + PAD * 2
      }));
    };
    setTimeout(report, 200);
    setTimeout(report, 1000);
    return true;
  };

  window.__zrCompact = compact;

  // --- readiness --------------------------------------------------------------

  const poll = setInterval(() => {
    if (compact()) {
      clearInterval(poll);
      send('ready', location.href);
    }
  }, 300);
  setTimeout(() => clearInterval(poll), 120000);
})();
