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
      n.style.setProperty('filter', 'none', 'important');
      n.style.setProperty('backdrop-filter', 'none', 'important');
      n.style.setProperty('transform', 'none', 'important');
      n.style.setProperty('inset', 'auto', 'important');
      // Whatever painted the stray blurred shape below the pill (a
      // pseudo-element glow, a filter, a decorative background) is either
      // neutralized above or, if it comes from somewhere `style.setProperty`
      // cannot reach such as a ::before, clipped here: overflow:hidden cuts
      // any paint effect at this box's own edge regardless of what produced
      // it, without touching the real, in-flow content inside.
      n.style.setProperty('overflow', 'hidden', 'important');
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

    // A dictation that runs long turns the composer into several lines. The
    // two timed reports above only ever caught the bar's size at load time,
    // so the macOS window stayed frozen at its first, one line height and
    // clipped everything typed after that. Watching the box itself keeps the
    // window matched to the content for as long as dictation runs.
    if (!window.__zrResizeObserver) {
      window.__zrResizeObserver = new ResizeObserver(report);
      window.__zrResizeObserver.observe(target);
    }

    return true;
  };

  window.__zrCompact = compact;

  // --- 3. drive dictation from Cmd+D -------------------------------------

  // Matched by pattern, not by an exact label: the stop control has been seen
  // as "Submit dictation" on one build and "Stop dictation" on another.
  // Hard coding either one made the app believe dictation had vanished while
  // it was in fact still running.
  const match = (re) =>
    [...document.querySelectorAll('button')].find((b) =>
      re.test(b.getAttribute('aria-label') || '')
    );

  window.__zrToggleDictation = () => {
    const stop = match(/(stop|submit|finish|end|done)\s+dictation/i);
    if (stop) { stop.click(); return 'stopped'; }
    const start = match(/start\s+dictation|begin\s+dictation/i);
    if (start) { start.click(); return 'started'; }
    return 'no-button';
  };

  // --- readiness --------------------------------------------------------------

  const poll = setInterval(() => {
    if (compact()) {
      clearInterval(poll);
      send('ready', location.href);
    }
  }, 300);
  setTimeout(() => clearInterval(poll), 120000);
})();
