// 3 October 2026, 16:30 CEST: exercise real bridge failure paths without a network or microphone.
import vm from 'node:vm';
import fs from 'node:fs/promises';
import assert from 'node:assert/strict';
const source = await fs.readFile(new URL('../Sources/ZenRayDictate/Resources/GeminiBridge.js',import.meta.url),'utf8');
function harness(host='gemini.google.com') {
  const reports=[]; let microphoneCalls=0; let lastConstraints; let clicks=0;
  const field={innerText:'An unrelated draft',focus(){}};
  const mic={disabled:false,getClientRects:()=>[1],getAttribute:()=> 'Dictate',click(){clicks++}};
  const context={location:{hostname:host},navigator:{mediaDevices:{enumerateDevices:async()=>[{kind:'audioinput',label:'MacBook Pro Microphone',deviceId:'builtin'},{kind:'audioinput',label:'AirPods',deviceId:'airpods'}],getUserMedia:async constraints=>{lastConstraints=constraints;microphoneCalls++;return 'real mic'}}},document:{querySelector:()=>field,querySelectorAll:()=>[mic]},window:{webkit:{messageHandlers:{dictation:{postMessage:payload=>reports.push(payload)}}}},setTimeout,Uint8Array,atob};
  vm.runInNewContext(source,context);
  return {context,reports,counts:()=>({microphoneCalls,clicks,lastConstraints})};
}
const offsite=harness('example.com'); assert.equal(offsite.context.window.ZenRayGemini,undefined);
const h=harness(); const bridge=h.context.window.ZenRayGemini;
assert.equal(bridge.ready(),true);
await bridge.transcribe({id:'draft',audio:''});
assert.match(h.reports[0].error,/draft/); assert.equal(h.counts().clicks,0); assert.equal(h.counts().microphoneCalls,0);
await bridge.rewrite({id:'rewrite',text:'test',instruction:'test'});
assert.match(h.reports[1].error,/draft/);
assert.equal(await h.context.navigator.mediaDevices.getUserMedia({audio:true}),'real mic');
assert.equal(h.counts().microphoneCalls,1);
assert.equal(h.counts().lastConstraints.audio.deviceId.exact,'builtin');
await h.context.navigator.mediaDevices.getUserMedia({audio:{deviceId:{exact:'airpods'},echoCancellation:true}});
assert.equal(h.counts().lastConstraints.audio.deviceId.exact,'builtin');
assert.equal(h.counts().lastConstraints.audio.echoCancellation,true);
await bridge.cancel();
console.log('Gemini bridge guards passed: wrong origin, unrelated draft, no microphone on rejection, cleanup after error, cached AirPods ID replaced with built-in microphone.');
