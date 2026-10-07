// 3 October 2026, 22:23 CEST: verify completion waits for final text, copies once and preserves unrelated drafts.
import vm from 'node:vm';
import fs from 'node:fs/promises';
import assert from 'node:assert/strict';
const source=await fs.readFile(new URL('../Sources/ZenRayDictate/Resources/GeminiComposer.js',import.meta.url),'utf8');
const messages=[],timers=[];
let recording=false,value='',finalText='Final transcript.',busy=false,clicks=0;
const field={get innerText(){return value},focus(){}};
const microphone={disabled:false,getClientRects:()=>[1],getAttribute:()=> 'Dictate',click(){recording=true;clicks++;value='Partial transcript';}};
const stop={disabled:false,getClientRects:()=>[1],getAttribute:()=> 'Stop dictation',click(){recording=false;setTimeout(()=>{value=finalText},350)}};
const document={documentElement:{setAttribute(){},removeAttribute(){}},head:{append(el){el.isConnected=true}},createElement:()=>({isConnected:false}),querySelector:selector=>selector.includes('contenteditable')?field:null,querySelectorAll:selector=>selector==='button[aria-label]'?[recording?stop:microphone]:[],createRange:()=>({selectNodeContents(){}}),execCommand(command){if(command==='delete')value=''}};
const context={location:{hostname:'gemini.google.com'},window:{ZenRayGemini:{isBusy:()=>busy},webkit:{messageHandlers:{liveCapture:{postMessage:p=>messages.push(p)}}}},document,ResizeObserver:class{observe(){}disconnect(){}},MutationObserver:class{observe(){}},setTimeout,setInterval(fn,ms){const t=setInterval(fn,ms);timers.push(t);return t},getSelection:()=>({removeAllRanges(){},addRange(){}}),Date,Promise};
vm.runInNewContext(source,context);
const composer=context.window.ZenRayComposer;
try{
 await composer.begin();assert.equal(recording,true);
 const result=await composer.end();assert.equal(result,'Final transcript.');
 assert.equal(messages.filter(m=>m.state==='finished').length,1);
 await composer.end();assert.equal(messages.filter(m=>m.state==='finished').length,1);
 await composer.begin();assert.equal(recording,true);finalText='Second capture.';
 await composer.end();assert.equal(messages.at(-1).text,'Second capture.');
 value='Unrelated draft';finalText=value;await composer.begin();value='Unrelated draft';
 assert.equal(await composer.end(),'');assert.equal(value,'Unrelated draft');
 const before=clicks;busy=true;assert.equal(await composer.begin(),false);assert.equal(clicks,before);busy=false;
 await composer.begin();composer.cancel();await new Promise(r=>setTimeout(r,1100));assert.notEqual(messages.at(-1).state,'finished');
 console.log('Composer capture passed: delayed final text, one completion per capture, separate captures, unchanged draft preserved, busy request rejected, cancel does not copy.');
}finally{timers.forEach(clearInterval)}
