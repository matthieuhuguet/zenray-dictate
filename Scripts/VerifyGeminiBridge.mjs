// 3 October 2026, 16:30 CEST: exercise real bridge failure paths without a network or microphone.
// 10 October 2026: also verify window.ZenRayNativeMic live PCM16 streaming into MediaStreamDestination.
import vm from 'node:vm';
import fs from 'node:fs/promises';
import assert from 'node:assert/strict';
const source = await fs.readFile(new URL('../Sources/ZenRayDictate/Resources/GeminiBridge.js',import.meta.url),'utf8');
function harness(host='gemini.google.com', withNativeMic=false) {
  const reports=[]; const nativeMicActions=[]; let microphoneCalls=0; let lastConstraints; let clicks=0;
  const field={innerText:'An unrelated draft',focus(){}};
  const mic={disabled:false,getClientRects:()=>[1],getAttribute:()=> 'Dictate',click(){clicks++}};
  const handlers={dictation:{postMessage:payload=>reports.push(payload)}};
  if (withNativeMic) {
    handlers.nativeMic = { postMessage: payload => nativeMicActions.push(payload) };
  }
  let trackStopped = 0;
  class FakeAudioContext {
    constructor() { this.state = 'running'; this.currentTime = 0; }
    async resume() { this.state = 'running'; }
    async close() { this.state = 'closed'; }
    createGain() { return { gain: { value: 1 }, connect() {} }; }
    createBuffer(channels, length, sampleRate) {
      const data = new Float32Array(length);
      return { length, sampleRate, duration: length / sampleRate, getChannelData: () => data };
    }
    createBufferSource() {
      return { buffer: null, connect() {}, start() {} };
    }
    createMediaStreamDestination() {
      const track = { stop() { trackStopped++; }, applyConstraints: async () => {} };
      return { stream: { id: 'native-stream', getTracks: () => [track] } };
    }
  }
  const context={location:{hostname:host},navigator:{mediaDevices:{enumerateDevices:async()=>[{kind:'audioinput',label:'MacBook Pro Microphone',deviceId:'builtin'},{kind:'audioinput',label:'AirPods',deviceId:'airpods'}],getUserMedia:async constraints=>{lastConstraints=constraints;microphoneCalls++;return 'real mic'}}},document:{querySelector:()=>field,querySelectorAll:()=>[mic]},window:{webkit:{messageHandlers:handlers}},AudioContext:FakeAudioContext,setTimeout,Uint8Array,atob};
  vm.runInNewContext(source,context);
  return {context,reports,nativeMicActions,counts:()=>({microphoneCalls,clicks,lastConstraints,trackStopped})};
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
assert.equal(h.counts().lastConstraints.audio.deviceId,undefined);
await h.context.navigator.mediaDevices.getUserMedia({audio:{deviceId:{exact:'airpods'},echoCancellation:true}});
assert.equal(h.counts().lastConstraints.audio.deviceId,undefined);
assert.equal(h.counts().lastConstraints.audio.echoCancellation,true);
await bridge.cancel();

// 10 October 2026: verify NativeMicrophoneBridge WebAudio stream bypasses WebKit VPIO getUserMedia.
const hn = harness('gemini.google.com', true);
const stream = await hn.context.navigator.mediaDevices.getUserMedia({audio:{echoCancellation:true}});
assert.equal(stream.id, 'native-stream');
assert.equal(hn.counts().microphoneCalls, 0);
assert.equal(hn.nativeMicActions.length, 1);
assert.equal(hn.nativeMicActions[0].action, 'start');
assert.equal(hn.context.window.ZenRayNativeMic.isActive(), true);
const pcm = Buffer.alloc(64);
hn.context.window.ZenRayNativeMic.pushPCM16(pcm.toString('base64'), 16000);
assert.equal(hn.context.window.ZenRayNativeMic.chunksReceived(), 1);
stream.getTracks()[0].stop();
assert.equal(hn.context.window.ZenRayNativeMic.isActive(), false);
assert.equal(hn.nativeMicActions.length, 2);
assert.equal(hn.nativeMicActions[1].action, 'stop');

console.log('Gemini bridge guards passed: wrong origin, unrelated draft, no microphone on rejection, cleanup after error, cached device ID removed, and nativeMic AUHAL WebAudio stream verified.');
