// Prints what macOS currently reports as Now Playing.
// Usage: osascript -l JavaScript tools/now-playing.js
ObjC.import('Foundation');
$.NSBundle.bundleWithPath('/System/Library/PrivateFrameworks/MediaRemote.framework/').load;
const R = $.NSClassFromString('MRNowPlayingRequest');
const info = R.localNowPlayingItem.nowPlayingInfo;
const g = (k) => {
  const v = info.objectForKey(k);
  return v.isNil() ? null : ObjC.unwrap(v.description);
};
JSON.stringify({
  app: ObjC.unwrap(R.localNowPlayingPlayerPath.client.bundleIdentifier),
  title: g('kMRMediaRemoteNowPlayingInfoTitle'),
  artist: g('kMRMediaRemoteNowPlayingInfoArtist'),
  album: g('kMRMediaRemoteNowPlayingInfoAlbum'),
  duration: g('kMRMediaRemoteNowPlayingInfoDuration'),
  elapsed: g('kMRMediaRemoteNowPlayingInfoElapsedTime'),
  playing: R.localIsPlaying,
});
