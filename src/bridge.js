// Qobuz -> macOS Now Playing bridge.
// Qobuz plays audio through a native JUCE engine, so Chromium never registers a
// media session and macOS never learns what is playing. This script, injected
// into the Qobuz renderer, mirrors the Redux player state into
// navigator.mediaSession and keeps a silent looping <audio> element alive so
// Chromium publishes it to Control Center / lock screen / media keys.
(() => {
  if (window.__qobuzNowPlaying) return 'already installed';

  const findStore = () => {
    for (const el of document.querySelectorAll('body, body > *, #root, #app')) {
      const key = Object.keys(el).find((k) => k.startsWith('__reactContainer'));
      if (!key) continue;
      const stack = [el[key]];
      let visited = 0;
      while (stack.length && visited++ < 20000) {
        const node = stack.pop();
        if (!node) continue;
        const store = node.memoizedProps && node.memoizedProps.store;
        if (store && typeof store.getState === 'function') return store;
        if (node.sibling) stack.push(node.sibling);
        if (node.child) stack.push(node.child);
      }
    }
    return null;
  };

  const store = findStore();
  if (!store) return 'store not ready';

  // 10s of 8 kHz mono 8-bit silence. Chromium ignores media shorter than 5s.
  const silentWavUrl = (() => {
    const samples = 8000 * 10;
    const buf = new ArrayBuffer(44 + samples);
    const v = new DataView(buf);
    const str = (o, s) => [...s].forEach((c, i) => v.setUint8(o + i, c.charCodeAt(0)));
    str(0, 'RIFF'); v.setUint32(4, 36 + samples, true); str(8, 'WAVE');
    str(12, 'fmt '); v.setUint32(16, 16, true); v.setUint16(20, 1, true);
    v.setUint16(22, 1, true); v.setUint32(24, 8000, true); v.setUint32(28, 8000, true);
    v.setUint16(32, 1, true); v.setUint16(34, 8, true);
    str(36, 'data'); v.setUint32(40, samples, true);
    new Uint8Array(buf, 44).fill(128);
    return URL.createObjectURL(new Blob([buf], { type: 'audio/wav' }));
  })();

  const audio = document.createElement('audio');
  audio.src = silentWavUrl;
  audio.loop = true;
  audio.style.display = 'none';
  document.body.appendChild(audio);

  const click = (selector) => {
    const el = document.querySelector(selector);
    if (el) el.click();
  };
  const isPlaying = () => store.getState().player.playingState === 'play';
  const ms = navigator.mediaSession;
  ms.setActionHandler('play', () => { if (!isPlaying()) click('.player__action-play, .player__action-pause'); });
  ms.setActionHandler('pause', () => { if (isPlaying()) click('.player__action-pause, .player__action-play'); });
  ms.setActionHandler('previoustrack', () => click('.player__action-previous'));
  ms.setActionHandler('nexttrack', () => click('.player__action-next'));

  let lastTrackId = null;
  let lastPlaying = null;
  let lastPositionKey = null;

  const sync = () => {
    const state = store.getState();
    const player = state.player || {};
    const current = player.currentTrack;
    if (!current) return;
    const dict = state.dictionnary || {};
    const track = dict.tracks && dict.tracks.data && dict.tracks.data[current.id];

    if (track && current.id !== lastTrackId) {
      const release = dict.releases && dict.releases.data && dict.releases.data[track.releaseId];
      const artist =
        (track.interpreters || []).map((a) => a.name && a.name.display).filter(Boolean).join(', ') ||
        (release && (release.artists || []).map((a) => a.name && a.name.display).join(', ')) ||
        '';
      const title = track.version ? `${track.title} (${track.version})` : track.title;
      const img = release && release.image;
      ms.metadata = new MediaMetadata({
        title,
        artist,
        album: release ? release.title : '',
        artwork: img
          ? [
              { src: img.small, sizes: '230x230', type: 'image/jpeg' },
              { src: img.large, sizes: '600x600', type: 'image/jpeg' },
            ].filter((a) => a.src)
          : [],
      });
      lastTrackId = current.id;
      lastPositionKey = null;
    }

    const playing = player.playingState === 'play';
    if (playing !== lastPlaying) {
      if (playing) audio.play().catch(() => {});
      else audio.pause();
      ms.playbackState = playing ? 'playing' : 'paused';
      lastPlaying = playing;
    }

    const pos = player.position;
    const duration = (current.duration || 0) / 1000;
    if (pos && duration > 0) {
      const key = `${pos.value}:${pos.timestamp}:${playing}`;
      if (key !== lastPositionKey) {
        let position = pos.value / 1000;
        if (playing && pos.timestamp) position += (Date.now() - pos.timestamp) / 1000;
        try {
          ms.setPositionState({
            duration,
            position: Math.min(Math.max(position, 0), duration),
            playbackRate: 1,
          });
        } catch (e) {}
        lastPositionKey = key;
      }
    }
  };

  const unsubscribe = store.subscribe(sync);
  sync();
  window.__qobuzNowPlaying = { unsubscribe, audio, sync };
  return 'installed';
})();
