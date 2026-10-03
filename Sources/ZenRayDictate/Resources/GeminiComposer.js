// 3 October 2026, 21:35 CEST: isolate the real Angular composer without cloning or relocating its DOM.
(() => {
  if (location.hostname !== 'gemini.google.com') return;
  const settings = { composer: 'input-container', editor: '[role="textbox"][contenteditable="true"]' };
  let compact = false;
  const style = document.createElement('style');
  style.textContent = `
    html[data-zenray-compact] [data-zenray-hidden] { display:none!important; }
    html[data-zenray-compact], html[data-zenray-compact] body { margin:0!important; padding:0!important; overflow:hidden!important; background:transparent!important; }
    html[data-zenray-compact] [data-zenray-path] { position:static!important; transform:none!important; padding:0!important; margin:0!important; min-height:0!important; height:auto!important; width:100%!important; max-width:none!important; overflow:visible!important; background:transparent!important; }
    html[data-zenray-compact] [data-zenray-composer] { position:fixed!important; top:6px!important; left:6px!important; right:6px!important; bottom:auto!important; width:auto!important; max-width:none!important; height:auto!important; margin:0!important; z-index:100!important; }
    html[data-zenray-compact] [data-zenray-composer] .input-area-container { margin:0!important; width:100%!important; max-width:none!important; }
    html[data-zenray-compact] [data-zenray-composer] rich-textarea .ql-editor { max-height:145px!important; overflow-y:auto!important; }
    html[data-zenray-compact] [data-zenray-composer] .input-area-container > p { display:none!important; }
    html[data-zenray-compact] hallucination-disclaimer { display:none!important; }
    html[data-zenray-compact] .cdk-overlay-container { position:fixed!important; z-index:1000!important; }
  `;
  let previousRoot = null, lastHeight = 0;
  const resize = new ResizeObserver(()=>{
    if (!compact) return;
    const area=document.querySelector(settings.composer+' .input-area');
    if(!area)return;
    const height=Math.ceil(area.getBoundingClientRect().height+12);
    if(height!==lastHeight){lastHeight=height;window.webkit?.messageHandlers?.composerLayout?.postMessage({height});}
  });
  function apply() {
    if (!document.documentElement) return;
    if (!style.isConnected) (document.head || document.documentElement).append(style);
    const root = document.querySelector(settings.composer);
    // Keep the complete page visible for sign-in, errors or an upstream DOM change.
    if (!compact || !root || !root.querySelector(settings.editor)) {
      document.documentElement.removeAttribute('data-zenray-compact'); return;
    }
    document.documentElement.setAttribute('data-zenray-compact','');
    if (root === previousRoot && root.hasAttribute('data-zenray-composer')) return;
    document.querySelectorAll('[data-zenray-hidden],[data-zenray-path],[data-zenray-composer]').forEach(el=>{
      el.removeAttribute('data-zenray-hidden'); el.removeAttribute('data-zenray-path'); el.removeAttribute('data-zenray-composer');
    });
    previousRoot = root;
    resize.disconnect(); const area=root.querySelector('.input-area'); if(area)resize.observe(area);
    root.setAttribute('data-zenray-composer','');
    const legal=root.querySelector('a[href*="policies.google.com"]');
    if(legal){ let footer=legal; while(footer.parentElement && footer.parentElement!==root && !footer.parentElement.querySelector(settings.editor)){footer=footer.parentElement;} footer.setAttribute('data-zenray-hidden',''); }
    let child = root;
    while (child.parentElement && child.parentElement !== document.documentElement) {
      const parent = child.parentElement;
      parent.setAttribute('data-zenray-path','');
      for (const sibling of parent.children) {
        if (sibling !== child && sibling !== style && !sibling.matches('.cdk-overlay-container,script,style,link')) sibling.setAttribute('data-zenray-hidden','');
      }
      child = parent;
    }
  }
  window.ZenRayComposer = {
    setCompact(value) { compact = Boolean(value); previousRoot = null; apply(); },
    microphone(stop = false) {
      const pattern = stop ? /^(Arrêter|Stop|Terminer|Done)(?:\s|$)/i : /^(Dicter|Dictate|Use microphone|Microphone)(?:\s|$)/i;
      const button = [...document.querySelectorAll('button[aria-label]')].find(el=>!el.disabled&&el.getClientRects().length&&pattern.test(el.getAttribute('aria-label')));
      if (!button) throw new Error(stop ? 'Gemini microphone is not recording.' : 'Gemini microphone is unavailable. Open the full session to check access.');
      button.click();
    },
    cancel() { const button = [...document.querySelectorAll('button[aria-label]')].find(el=>/^(Arrêter|Stop|Terminer|Done)(?:\s|$)/i.test(el.getAttribute('aria-label'))); button?.click(); },
    state() { const root=document.querySelector(settings.composer); return {origin:location.origin,compact:document.documentElement.hasAttribute('data-zenray-compact'),composer:root?.tagName,editor:!!root?.querySelector(settings.editor)}; }
  };
  new MutationObserver(apply).observe(document,{childList:true,subtree:true});
  apply();
})();
