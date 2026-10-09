// Qobuz -> macOS Now Playing bridge, page half.
// Qobuz plays audio through a native JUCE engine, so Chromium never registers a
// media session and macOS never learns what is playing. This script, injected
// into the Qobuz renderer, reads the player, queue and favorites from the app's
// Redux store and reports them to the main process, where the watcher's host
// publishes them through a native addon (src/native/nowplaying.m). The page
// has no IPC of its own, so reports go out as console messages with a marker
// the host listens for. The host calls command() for the remote commands that
// need the page; the rest go through Qobuz's own menu IPC.
(() => {
  // Bump when changing this file so the watcher replaces an older injected copy.
  const VERSION = 4;
  const MARKER = '⁣qobuz-now-playing:';
  const previous = window.__qobuzNowPlaying;
  if (previous && previous.version === VERSION) {
    previous.resend();
    return 'already installed';
  }

  // Depth-first search of the React fiber tree for a component prop.
  const findProp = (name, test) => {
    for (const el of document.querySelectorAll('body, body > *, #root, #app')) {
      const key = Object.keys(el).find((k) => k.startsWith('__reactContainer'));
      if (!key) continue;
      const stack = [el[key]];
      let visited = 0;
      while (stack.length && visited++ < 20000) {
        const node = stack.pop();
        if (!node) continue;
        const value = node.memoizedProps && node.memoizedProps[name];
        if (value && test(value)) return value;
        if (node.sibling) stack.push(node.sibling);
        if (node.child) stack.push(node.child);
      }
    }
    return null;
  };
  const isFunction = (f) => typeof f === 'function';

  const store = findProp('store', (s) => typeof s.getState === 'function');
  if (!store) return 'store not ready';

  if (previous) {
    if (previous.dispose) previous.dispose();
    if (previous.unsubscribe) previous.unsubscribe();
    // Version 2 published through the page's media session with a silent
    // <audio>; end that session so Chromium lets go of Now Playing.
    if (previous.audio) {
      previous.audio.pause();
      previous.audio.remove();
      const ms = navigator.mediaSession;
      for (const action of ['play', 'pause', 'previoustrack', 'nexttrack', 'seekto', 'stop'])
        try { ms.setActionHandler(action, null); } catch (e) {}
      ms.metadata = null;
      ms.playbackState = 'none';
    }
  }

  const names = (people) => (people || []).map((a) => a.name && a.name.display).filter(Boolean).join(', ');
  const describe = (dict, trackId) => {
    const track = dict.tracks && dict.tracks.data && dict.tracks.data[trackId];
    if (!track || !track.title) return null;
    const release = dict.releases && dict.releases.data && dict.releases.data[track.releaseId];
    return { track, release, artist: names(track.interpreters) || (release && names(release.artists)) || '' };
  };
  const titleOf = (track) => (track.version ? `${track.title} (${track.version})` : track.title);

  // The play queue in play order, then the autoplay tracks Qobuz adds after it.
  const queueOf = (state) => {
    const pq = state.playqueue || {};
    const order = (pq.shuffled ? pq.shuffledItems : pq.items) || [];
    const autoplay = (pq.autoplay && pq.autoplay.mode && pq.autoplay.items) || [];
    return { order, autoplay, index: pq.currentIndex };
  };

  // Ask Qobuz to load tracks it hasn't fetched yet (it does the same for its
  // autoplay panel), at most once each.
  const requested = new Set();
  const loadMissing = (dict, ids) => {
    const missing = ids.filter((id) => !requested.has(id) && !(dict.tracks && dict.tracks.data && dict.tracks.data[id]));
    if (!missing.length) return;
    missing.forEach((id) => requested.add(id));
    store.dispatch({ type: 'LOAD_TRACKS_EPIC', ids: missing });
  };

  // Up Next: up to 10 tracks back and 50 ahead of the current one.
  const QUEUE_BEFORE = 10;
  const QUEUE_AFTER = 50;
  const queueMessage = (state) => {
    const dict = state.dictionnary || {};
    const { order, autoplay, index } = queueOf(state);
    if (index == null || index < 0 || !order[index]) return { type: 'queue', items: [], current: -1 };
    const slice = [
      ...order.slice(Math.max(0, index - QUEUE_BEFORE), index + 1 + QUEUE_AFTER).map((item) => ({ item, playable: true })),
      ...autoplay.map((item) => ({ item, playable: false })),
    ].slice(0, QUEUE_BEFORE + 1 + QUEUE_AFTER);
    loadMissing(dict, slice.map(({ item }) => item.trackId));
    const currentId = order[index].queueItemId;
    const items = [];
    let current = -1;
    for (const { item, playable } of slice) {
      const info = describe(dict, item.trackId);
      // Unloaded tracks are left out until Qobuz has their details.
      if (!info) continue;
      if (item.queueItemId === currentId) current = items.length;
      items.push({
        id: item.queueItemId,
        title: titleOf(info.track),
        artist: info.artist,
        album: info.release ? info.release.title : '',
        duration: info.track.duration,
        artworkUrl: info.release && info.release.image ? info.release.image.small : null,
        // Qobuz only jumps to tracks in the play queue itself; an autoplay
        // track is played by reaching it.
        playable,
      });
    }
    return { type: 'queue', items, current };
  };

  const stateMessage = (state) => {
    const player = state.player || {};
    const current = player.currentTrack;
    const info = current && describe(state.dictionnary || {}, current.id);
    if (!info) return { type: 'state', track: null };
    const { track, release, artist } = info;
    const pq = state.playqueue || {};
    const { order, autoplay, index } = queueOf(state);
    const favorites = state.userLibrary && state.userLibrary.chunks && state.userLibrary.chunks.favoriteTracks;
    const media = track.mediaSupport || {};
    const playing = player.playingState === 'play';
    // The output Qobuz plays to, and the format it streams (formats 6, 7 and
    // 27 are FLAC, 5 is MP3).
    const outputs = state.audioOutputs || {};
    const outputId = outputs.current && typeof outputs.current === 'object' ? outputs.current.uid : outputs.current;
    const output = outputs.dictionnary && outputs.dictionnary[outputId];
    const quality = player.quality || {};
    return {
      type: 'state',
      track: {
        id: track.id,
        itemId: order[index] ? order[index].queueItemId : undefined,
        title: titleOf(track),
        artist,
        album: release ? release.title : '',
        albumArtist: release ? names(release.artists) : undefined,
        composer: track.composer && track.composer.name ? track.composer.name.display : undefined,
        genre: release && release.genre ? release.genre.name : undefined,
        trackNumber: media.trackNumber,
        trackCount: release ? release.tracksCount : undefined,
        discNumber: media.mediaNumber,
        discCount: release ? release.mediasCount : undefined,
        isrc: track.isrc || undefined,
        explicit: !!track.parentalWarning,
        duration: (current.duration || 0) / 1000,
        artworkUrl: release && release.image ? release.image.large || release.image.small : null,
        output: output ? output.displayName : undefined,
        sampleRate: quality.samplingRate ? Math.round(quality.samplingRate * 1000) : undefined,
        bitDepth: quality.bitDepth || undefined,
        codec: quality.formatId ? (quality.formatId === 5 ? 'mp3' : 'flac') : undefined,
      },
      playing,
      position: player.position ? { value: player.position.value, timestamp: player.position.timestamp } : null,
      // Qobuz's local outputs, so the host can follow the macOS default output.
      outputs: {
        local: !!output && output.controllerType === 'JUCE',
        current: outputId,
        direct: ((outputs.availables && outputs.availables.direct) || [])
          .map((uid) => outputs.dictionnary && outputs.dictionnary[uid])
          .filter(Boolean)
          .map((o) => ({ uid: o.uid, name: o.displayName, driverType: o.driverType })),
      },
      shuffle: !!pq.shuffled,
      repeat: pq.repeatMode || 'noRepeat',
      favorite: !!(favorites && favorites.mapById && favorites.mapById[track.id]),
      canNext: index + 1 < order.length || pq.repeatMode === 'repeatAll' || autoplay.length > 0,
      queueIndex: index,
      queueCount: order.length + autoplay.length,
    };
  };

  let lastState = null;
  let lastQueue = null;
  const sync = (force) => {
    const state = store.getState();
    const s = JSON.stringify(stateMessage(state));
    if (force || s !== lastState) {
      lastState = s;
      console.debug(MARKER + s);
    }
    const q = JSON.stringify(queueMessage(state));
    if (force || q !== lastQueue) {
      lastQueue = q;
      console.debug(MARKER + q);
    }
  };

  // Called by the host for commands Qobuz has no menu IPC for.
  let seekTimer = null;
  const positionNow = () => {
    const { player } = store.getState();
    const pos = player.position || { value: 0 };
    let ms = pos.value;
    if (player.playingState === 'play' && pos.timestamp) ms += Date.now() - pos.timestamp;
    return { ms, duration: (player.currentTrack && player.currentTrack.duration) || 0 };
  };
  const seek = (ms) => {
    const fn = findProp('seek', isFunction);
    if (!fn) return 'no seek';
    const { duration } = positionNow();
    fn({ position: Math.round(Math.min(Math.max(ms, 0), Math.max(duration - 1000, 0))) });
    return 'ok';
  };
  const command = (name, value) => {
    switch (name) {
      case 'seekTo':
        return seek(value * 1000);
      case 'skip':
        return seek(positionNow().ms + value * 1000);
      // A held media key: jump 10 s every half second until it's released.
      case 'seekForward':
      case 'seekBackward': {
        clearInterval(seekTimer);
        seekTimer = null;
        if (!value) return 'ok';
        const step = name === 'seekForward' ? 10000 : -10000;
        seek(positionNow().ms + step);
        seekTimer = setInterval(() => seek(positionNow().ms + step), 500);
        setTimeout(() => clearInterval(seekTimer), 60000);
        return 'ok';
      }
      case 'playItem': {
        const { order } = queueOf(store.getState());
        const index = order.findIndex((item) => item.queueItemId === value);
        if (index < 0) return 'not in the play queue';
        // Qobuz's own "play this track in the queue" action, bound to the
        // store by any mounted track row.
        const moveInQueue = findProp('moveInQueue', isFunction);
        if (!moveInQueue) return 'no moveInQueue';
        moveInQueue({ index });
        return 'ok';
      }
      default:
        return 'unknown command ' + name;
    }
  };

  const unsubscribe = store.subscribe(() => sync(false));
  sync(true);
  window.__qobuzNowPlaying = {
    version: VERSION,
    command,
    resend: () => sync(true),
    dispose() {
      unsubscribe();
      clearInterval(seekTimer);
    },
  };
  return previous ? 'updated' : 'installed';
})();
