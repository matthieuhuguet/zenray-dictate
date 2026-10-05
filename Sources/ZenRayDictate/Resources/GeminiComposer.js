// 3 October 2026, 21:35 CEST: isolate the real Angular composer without cloning or relocating its DOM.
(() => {
  if (location.hostname !== 'gemini.google.com') return;
  const settings = { composer: 'input-container', editor: '[role="textbox"][contenteditable="true"]', settleMs: 900, pollMs: 100, finishTimeoutMs: 20000, readyTimeoutMs: 15000 };
  let compact = false;
  const style = document.createElement('style');
  style.textContent = `
    html[data-zenray-compact] [data-zenray-hidden] { display:none!important; }
    html[data-zenray-compact], html[data-zenray-compact] body { margin:0!important; padding:0!important; overflow:hidden!important; background:transparent!important; }
    html[data-zenray-compact] [data-zenray-path] { position:static!important; transform:none!important; padding:0!important; margin:0!important; min-height:0!important; height:auto!important; width:100%!important; max-width:none!important; overflow:visible!important; background:transparent!important; }
    html[data-zenray-compact] [data-zenray-composer] { position:fixed!important; top:6px!important; left:6px!important; right:6px!important; bottom:auto!important; width:auto!important; max-width:none!important; height:auto!important; margin:0!important; z-index:100!important; }
    html[data-zenray-compact] [data-zenray-composer] .input-area-container { margin:0!important; width:100%!important; max-width:none!important; }
    html[data-zenray-compact] [data-zenray-composer] rich-textarea .ql-editor { max-height:340px!important; overflow-y:auto!important; }
    html[data-zenray-compact] [data-zenray-composer] .input-area-container > p { display:none!important; }
    html[data-zenray-compact] .input-area-fieldset { min-width:0!important; padding:0!important; margin:0!important; border:0!important; }
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
  // 3 October 2026, 22:15 CEST: completion follows the website's real stop state, including manual microphone clicks.
  const field = () => document.querySelector(settings.editor);
  const text = () => (field()?.innerText || '').trim();
  const findButton = pattern => [...document.querySelectorAll('button[aria-label]')].find(el=>!el.disabled&&el.getClientRects().length&&pattern.test(el.getAttribute('aria-label') || ''));
  const microphone = () => {
    return findButton(/^(Dicter|Dictate|Use microphone|Microphone|Utiliser le microphone|Activer le microphone)(?:\s|$)/i) ||
      document.querySelector('button[aria-label*="micro" i]:not([aria-label*="arr[êe]t" i]):not([aria-label*="stop" i])');
  };
  const stopButton = () => {
    return findButton(/^(Arrêter la dictée|Arrêter l'écoute|Arrêter|Stop dictation|Stop listening|Stop|Terminer|Done)(?:\s|$)/i) ||
      document.querySelector('butterfly-wave-view button, button[aria-label*="arr[êe]t" i], button[aria-label*="stop" i]');
  };
  const isWaveformActive = () => Boolean(document.querySelector('butterfly-wave-view canvas'));
  const sleep = ms => new Promise(resolve=>setTimeout(resolve,ms));
  const notify = payload => window.webkit?.messageHandlers?.liveCapture?.postMessage(payload);
  let capture=null, finalizing=null, lastCompleted='', counter=0;
  const busy = () => window.ZenRayGemini?.isBusy?.() === true;
  function opened() {
    if(capture || busy())return;
    capture={id:String(++counter)+'-'+Date.now(),baseline:text(),cancelled:false,started:false};
    notify({state:'recording',id:capture.id});
  }
  async function finalize() {
    if(finalizing)return finalizing;
    if(!capture)return '';
    const current=capture;
    // 4 October 2026: relocate the preview immediately; clipboard completion still waits for final text.
    notify({state:'finishing',id:current.id});
    finalizing=(async()=>{
      let previous=text(),changedAt=Date.now();
      const deadline=Date.now()+settings.finishTimeoutMs;
      while(Date.now()<deadline && !current.cancelled){
        await sleep(settings.pollMs);
        const value=text();
        if(value!==previous){previous=value;changedAt=Date.now();}
        if(!stopButton() && !isWaveformActive() && Date.now()-changedAt>=settings.settleMs){
          const result=previous!==current.baseline ? previous : '';
          if(result)lastCompleted=previous;
          notify({state:'finished',id:current.id,text:result});
          return result;
        }
      }
      if(!current.cancelled)throw new Error('Gemini did not finish its last transcript. The draft is preserved in the capsule.');
      return '';
    })();
    try{return await finalizing;}
    catch(error){notify({state:'error',id:current.id,error:error.message});throw error;}
    finally{if(capture===current)capture=null;finalizing=null;}
  }
  function observeCapture() {
    if(busy())return;
    if(stopButton() || isWaveformActive()){opened();if(capture)capture.started=true;}
    else if(capture?.started && !finalizing)finalize().catch(()=>{});
  }
  window.ZenRayComposer = {
    setCompact(value) { compact=Boolean(value);previousRoot=null;lastHeight=0;apply(); },
    async begin() {
      if(busy() || finalizing)return false;
      const deadline=Date.now()+settings.readyTimeoutMs;
      while(!microphone() && !stopButton() && !isWaveformActive() && Date.now()<deadline){
        await sleep(settings.pollMs);
      }
      if(stopButton() || isWaveformActive()){opened();if(capture)capture.started=true;return true;}
      const button=microphone();
      if(!button)return false;
      const current=text();
      if(current && current===lastCompleted){
        const editor=field();
        if(editor){
          try {
            editor.focus();
            const selection=getSelection();
            if(selection){
              const range=document.createRange();
              range.selectNodeContents(editor);
              selection.removeAllRanges();
              selection.addRange(range);
              document.execCommand('delete');
            }
          } catch(e) {}
        }
      }
      opened();
      button.click();
      while(!stopButton() && !isWaveformActive() && Date.now()<deadline)await sleep(settings.pollMs);
      if((stopButton() || isWaveformActive()) && capture)capture.started=true;
      if(!stopButton() && !isWaveformActive()){
        const id=capture?.id;
        capture=null;
        notify({state:'error',id,error:'Gemini did not start the microphone.'});
        return false;
      }
      return true;
    },
    async end() {
      try {
        if(busy())return '';
        if(stopButton()){opened();stopButton().click();}
        return await finalize();
      } catch(e) { return ''; }
    },
    microphone(stop=false) { return stop ? this.end() : this.begin(); },
    cancel() { if(capture){capture.cancelled=true;notify({state:'idle',id:capture.id});}stopButton()?.click();capture=null;return true; },
    state() { const root=document.querySelector(settings.composer);return {origin:location.origin,compact:document.documentElement.hasAttribute('data-zenray-compact'),composer:root?.tagName,editor:!!root?.querySelector(settings.editor),recording:Boolean(stopButton()||isWaveformActive()),finalizing:!!finalizing}; }
  };
  setInterval(observeCapture,settings.pollMs);
  new MutationObserver(apply).observe(document,{childList:true,subtree:true});
  apply();
})();
