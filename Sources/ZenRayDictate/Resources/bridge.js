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

  const findTarget = () => {
    const anchor =
      document.querySelector('#prompt-textarea') ||
      document.querySelector('div[contenteditable="true"]');
    if (!anchor) return null;
    return anchor.closest('form') || anchor.parentElement;
  };

  // Applies the hiding/flattening rules to whatever the composer's ancestor
  // chain is RIGHT NOW. Idempotent and cheap, safe to call as often as needed.
  //
  // It has to be, because ChatGPT swaps in a different DOM subtree for the
  // recording UI (the black pill with the live waveform) than for the idle
  // typing box. Styling was only ever applied once, when the page first
  // loaded in the idle state, so the moment dictation actually started, a
  // freshly mounted, unstyled wrapper appeared around the pill and painted
  // whatever glow or shadow it carries on the real page's white background,
  // where it normally blends in and is invisible.
  const neutralizeChain = (target) => {
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
  };

  // Resizing the macOS window changes the viewport width WKWebView renders
  // at, which can reflow the composer, which re-fires the resize watcher
  // below, which resizes the window again: a feedback loop that redrew the
  // UI on every tick. A report is dropped if it does not differ from the
  // last one SENT by more than a couple of pixels, and bursts are coalesced
  // to one report per 120ms.
  let lastSent = { width: 0, height: 0 };
  let debounceTimer = null;
  let resizeObserver = null;

  const report = (target) => {
    const r = target.getBoundingClientRect();
    if (r.height < 20) return;
    const width = Math.ceil(r.width) + PAD * 2;
    const height = Math.ceil(r.height) + PAD * 2;
    if (Math.abs(width - lastSent.width) < 3 && Math.abs(height - lastSent.height) < 3) return;
    lastSent = { width, height };
    send('compact', JSON.stringify({ width, height }));
  };

  const compact = () => {
    const target = findTarget();
    if (!target) return false;

    neutralizeChain(target);

    const reportDebounced = () => {
      clearTimeout(debounceTimer);
      debounceTimer = setTimeout(() => report(target), 120);
    };
    setTimeout(() => report(target), 200);
    setTimeout(() => report(target), 1000);

    // A dictation that runs long turns the composer into several lines; watch
    // the box itself so the window keeps matching it. `target` can be a new
    // DOM node each time compact() runs (see neutralizeChain above), so the
    // observer is redirected to it rather than created once and forgotten.
    if (!resizeObserver) resizeObserver = new ResizeObserver(reportDebounced);
    resizeObserver.disconnect();
    resizeObserver.observe(target);

    return true;
  };

  window.__zrCompact = compact;

  // React swaps the composer's DOM subtree between the idle and recording
  // states (see neutralizeChain's comment), so styling once at page load is
  // not enough: this catches every later swap and re-applies the same rules
  // to whatever just got mounted. `attributes` is deliberately left out —
  // our own style.setProperty calls only ever touch attributes, never add or
  // remove nodes, so they cannot re-trigger this observer themselves.
  let mutationTimer = null;
  const domObserver = new MutationObserver(() => {
    clearTimeout(mutationTimer);
    mutationTimer = setTimeout(compact, 80);
  });
  domObserver.observe(document.body, { childList: true, subtree: true });

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
