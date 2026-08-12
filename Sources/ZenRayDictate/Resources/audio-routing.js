// Keep ChatGPT input on a reliable local microphone. AirPods are never exposed
// to the page, so a missing MacBook/iPhone input fails instead of falling back
// silently to a Bluetooth microphone.
(() => {
  const blocked = /airpods|beats/i;

  const install = () => {
    const media = navigator.mediaDevices;
    if (!media?.getUserMedia || !media.enumerateDevices) return false;
    if (media.getUserMedia.__zrAudioRouting) return true;

    const nativeGetUserMedia = media.getUserMedia.bind(media);
    const nativeEnumerateDevices = media.enumerateDevices.bind(media);
    const microphones = () => nativeEnumerateDevices().then((devices) =>
      devices.filter((device) => device.kind === 'audioinput' && !blocked.test(device.label))
    );

    media.enumerateDevices = microphones;
    media.getUserMedia = async (constraints) => {
      if (!constraints?.audio) return nativeGetUserMedia(constraints);

      const inputs = await microphones();
      const chosen = inputs.find((device) => /macbook|built[- ]?in|internal microphone/i.test(device.label))
        || inputs.find((device) => /iphone/i.test(device.label));
      if (!chosen) {
        throw new DOMException('MacBook Pro or iPhone microphone required.', 'NotFoundError');
      }

      const audio = constraints.audio === true ? {} : { ...constraints.audio };
      delete audio.deviceId;
      delete audio.groupId;
      audio.deviceId = { exact: chosen.deviceId };
      return nativeGetUserMedia({ ...constraints, audio });
    };
    media.getUserMedia.__zrAudioRouting = true;
    return true;
  };

  if (!install()) {
    const poll = setInterval(() => { if (install()) clearInterval(poll); }, 50);
    setTimeout(() => clearInterval(poll), 10000);
  }
})();
