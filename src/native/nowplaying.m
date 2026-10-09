// Native half of the Qobuz -> macOS Now Playing bridge, loaded into the Qobuz
// main process as a Node-API addon (see src/watcher.mjs).
// Chromium only passes title/artist/album/artwork/position and seven commands
// from a page's media session to macOS. This addon publishes Now Playing for
// the process itself instead, through MediaPlayer, so it can offer what Music
// does: shuffle, repeat, favorites, skip and seek intervals, track details,
// and the Up Next queue that apps like Vorssaint read through MediaRemote.
//
// The queue uses MediaPlayer's private playback-queue data source. While one
// is set, MediaRemote ignores MPNowPlayingInfoCenter.nowPlayingInfo and takes
// the current track from the queue's current item instead, so everything,
// including the current track, is a queue item here. Their info dictionaries
// go to MediaRemote as they are, in its own kMRMediaRemoteNowPlayingInfo*
// keys, and MediaRemote archives them with secure coding: only strings,
// numbers, data and dates may go in, or the archiver throws and takes Qobuz
// down with it.
//
// JS API (all calls on the main thread):
//   start(onCommand)   onCommand(name, value) for each remote command, and
//                      ("systemOutput", device name) when the macOS default
//                      output changes, so Qobuz can follow it as Music does
//   update(state|null) current track and player state; null clears Now Playing
//   setQueue(items, currentIndex)
//   stop()             removes everything this addon registered
// Build with -DQNP_NO_NAPI to test the MediaPlayer side without Node.
#import <AppKit/AppKit.h>
#import <CoreAudio/CoreAudio.h>
#import <MediaPlayer/MediaPlayer.h>
#import <objc/message.h>

// Each build has its own class name, so a newer copy loaded into a Qobuz that
// still holds an older one doesn't clash with it.
#ifndef QNP_CLASS
#define QNP_CLASS QNPQueueDataSource
#endif

#pragma mark - Private MediaPlayer API

@interface MPNowPlayingContentItem : MPContentItem
- (instancetype)initWithIdentifier:(NSString *)identifier;
@property(copy) NSDictionary *nowPlayingInfo;
- (void)setElapsedTime:(double)elapsed playbackRate:(float)rate timestamp:(double)timestamp;
@end

@interface MPNowPlayingInfoCenter (QNPPrivate)
@property(weak) id playbackQueueDataSource;
- (void)invalidatePlaybackQueue;
@end

@interface MPRemoteCommandCenter (QNPPrivate)
@property(readonly) MPRemoteCommand *playItemInQueueCommand;
@property(readonly) MPRemoteCommand *advanceShuffleModeCommand;
@property(readonly) MPRemoteCommand *advanceRepeatModeCommand;
@property(readonly) MPFeedbackCommand *addNowPlayingItemToLibraryCommand;
@end

@interface MPRemoteCommandEvent (QNPPrivate)
@property(readonly) NSString *contentItemID;
@end

#pragma mark - State

typedef void (^QNPCommandHandler)(NSString *name, id value);  // value: NSNumber or NSString

static BOOL started;
static QNPCommandHandler onCommand;
static NSMutableArray *targets;                          // {command, target} pairs to remove on stop
static NSMutableDictionary<NSValue *, NSNumber *> *wantedEnabled;
static MPNowPlayingPlaybackState wantedState = MPNowPlayingPlaybackStateStopped;
static dispatch_source_t guardTimer;
static AudioObjectPropertyListenerBlock outputListener;
static id dataSource;
static BOOL attached;                                    // dataSource is set on the info center

// Shared with the data source, which MediaPlayer calls on its own queue.
// Queue entries are {id, track, playable}, track being the fields described
// at qnpUpdate. The current entry's id carries a revision ("q12#3"): an item
// MediaPlayer has fetched only passes on changes made through its typed
// setters (title, elapsed time and so on), and liked, shuffle, repeat and
// artwork have none, so a change to those publishes the track as a new item.
static NSLock *lock;
static NSArray<NSDictionary *> *pageQueue;               // as the page sent it
static NSInteger pageCurrent = -1;
static NSArray<NSDictionary *> *queue;                   // what MediaPlayer gets
static NSInteger queueCurrent = -1;
static NSString *currentBase;                            // the page's id for the current track
static NSString *currentId;                              // currentBase#revision
static NSUInteger revision;
static NSDictionary *currentTrack;                       // the current track's fields, without position
static double currentElapsed;
static BOOL currentPlaying;
static NSDictionary *currentArtwork;                     // the current track's artwork keys
static NSMutableDictionary<NSString *, MPNowPlayingContentItem *> *contentItems;

#define MR(name) @"kMRMediaRemoteNowPlayingInfo" name

// Everything that runs inside Qobuz goes through this: an Objective-C
// exception escaping here would terminate Qobuz.
#define GUARDED(label, fallback, body)                                   \
  @try {                                                                 \
    body                                                                 \
  } @catch (NSException * e) {                                           \
    NSLog(@"qobuz-now-playing: %s: %@", label, e);                       \
    fallback;                                                            \
  }

static NSString *baseId(NSString *identifier) {
  NSRange hash = [identifier rangeOfString:@"#" options:NSBackwardsSearch];
  return hash.location == NSNotFound ? identifier : [identifier substringToIndex:hash.location];
}

static id field(NSDictionary *t, NSString *name, Class type) {
  if (![t isKindOfClass:NSDictionary.class]) return nil;
  id value = t[name];
  return [value isKindOfClass:type] ? value : nil;
}

// Artwork keys for image data, or nil if it isn't an image.
static NSDictionary *artworkInfo(NSData *data, NSString *identifier) {
  if (![data isKindOfClass:NSData.class] || !data.length) return nil;
  NSBitmapImageRep *rep = [NSBitmapImageRep imageRepWithData:data];
  if (!rep) return nil;
  const uint8_t *b = data.bytes;
  NSString *mime = (data.length > 3 && b[0] == 0x89 && b[1] == 'P') ? @"image/png" : @"image/jpeg";
  return @{
    MR("ArtworkData") : data,
    MR("ArtworkMIMEType") : mime,
    MR("ArtworkDataWidth") : @(rep.pixelsWide),
    MR("ArtworkDataHeight") : @(rep.pixelsHigh),
    MR("ArtworkIdentifier") : [identifier isKindOfClass:NSString.class] && identifier.length
        ? identifier : [NSString stringWithFormat:@"%lx", (unsigned long)data.hash],
  };
}

static void setIf(id target, SEL setter, id value) {
  if (value && [target respondsToSelector:setter]) ((void (*)(id, SEL, id))objc_msgSend)(target, setter, value);
}
static void setIntegerIf(id target, SEL setter, NSNumber *value) {
  if (value && [target respondsToSelector:setter]) ((void (*)(id, SEL, NSInteger))objc_msgSend)(target, setter, value.integerValue);
}

// "Playing on …" and the stream's format, as Music shows them.
static void setRouteAndFormat(MPNowPlayingContentItem *item, NSDictionary *t) {
  NSString *output = field(t, @"output", NSString.class);
  Class Route = NSClassFromString(@"MPNowPlayingInfoAudioRoute");
  if (output && Route && [item respondsToSelector:@selector(setAudioRoute:)]) {
    id route = [Route new];
    setIf(route, @selector(setName:), output);
    [item setValue:route forKey:@"audioRoute"];
  }
  NSNumber *sampleRate = field(t, @"sampleRate", NSNumber.class);
  NSNumber *bitDepth = field(t, @"bitDepth", NSNumber.class);
  Class Format = NSClassFromString(@"MPNowPlayingInfoAudioFormat");
  if ((sampleRate || bitDepth) && Format && [item respondsToSelector:@selector(setActiveFormat:)]) {
    id format = [Format new];
    setIntegerIf(format, @selector(setSampleRate:), sampleRate);
    setIntegerIf(format, @selector(setBitDepth:), bitDepth);
    setIntegerIf(format, @selector(setTier:), field(t, @"tier", NSNumber.class));
    setIntegerIf(format, @selector(setCodec:), field(t, @"codec", NSNumber.class));
    [item setValue:format forKey:@"activeFormat"];
  }
}

// A queue item for a track, through MediaPlayer's typed setters where it has
// them. The info dictionary carries the rest, in MediaRemote's own keys.
static MPNowPlayingContentItem *makeContentItem(NSString *identifier, NSDictionary *t, BOOL playable, BOOL current) {
  MPNowPlayingContentItem *item = [[MPNowPlayingContentItem alloc] initWithIdentifier:identifier];
  NSMutableDictionary *info = [NSMutableDictionary dictionary];
  info[MR("MediaType")] = MR("TypeAudio");
  NSString *isrc = field(t, @"isrc", NSString.class);
  if (isrc) info[MR("InternationalStandardRecordingCode")] = isrc;
  NSDictionary *artwork = current ? currentArtwork : artworkInfo(t[@"artwork"], t[@"artworkId"]);
  if (artwork) {
    [info addEntriesFromDictionary:artwork];
    // MediaRemote doesn't resend artwork whose identifier it has sent before,
    // even for another item, so each item gets its own.
    info[MR("ArtworkIdentifier")] = [NSString stringWithFormat:@"%@ %@", artwork[MR("ArtworkIdentifier")], identifier];
  }
  if (current) {
    BOOL shuffle = [t[@"shuffle"] boolValue];
    // MediaRemote's shuffle and repeat modes are MediaPlayer's plus one.
    info[MR("ShuffleMode")] = @((shuffle ? MPShuffleTypeItems : MPShuffleTypeOff) + 1);
    info[MR("RepeatMode")] = @([t[@"repeat"] integerValue] + 1);
    info[MR("IsLiked")] = @([t[@"favorite"] boolValue]);
    info[MR("SupportsIsLiked")] = @YES;
    NSNumber *index = field(t, @"queueIndex", NSNumber.class), *count = field(t, @"queueCount", NSNumber.class);
    if (index) info[MR("QueueIndex")] = index;
    if (count) info[MR("TotalQueueCount")] = count;
  }
  item.nowPlayingInfo = info;
  // Clients fetch the current track's artwork on demand, through the item's
  // artwork object; MediaRemote drops the data from the info dictionary. (The
  // object itself must never go into the dictionary; see the top.)
  NSData *imageData = artwork[MR("ArtworkData")];
  NSImage *image = imageData ? [[NSImage alloc] initWithData:imageData] : nil;
  if (image) {
    item.artwork = [[MPMediaItemArtwork alloc] initWithBoundsSize:image.size
                                                   requestHandler:^NSImage *(CGSize size) { return image; }];
    if ([item respondsToSelector:@selector(setHasArtwork:)])
      ((void (*)(id, SEL, BOOL))objc_msgSend)(item, @selector(setHasArtwork:), YES);
  }

  item.title = field(t, @"title", NSString.class);
  item.playable = playable;
  setIf(item, @selector(setTrackArtistName:), field(t, @"artist", NSString.class));
  setIf(item, @selector(setAlbumName:), field(t, @"album", NSString.class));
  setIf(item, @selector(setAlbumArtistName:), field(t, @"albumArtist", NSString.class));
  setIf(item, @selector(setComposerName:), field(t, @"composer", NSString.class));
  setIf(item, @selector(setGenreName:), field(t, @"genre", NSString.class));
  setIntegerIf(item, @selector(setTrackNumber:), field(t, @"trackNumber", NSNumber.class));
  setIntegerIf(item, @selector(setTotalTrackCount:), field(t, @"trackCount", NSNumber.class));
  setIntegerIf(item, @selector(setDiscNumber:), field(t, @"discNumber", NSNumber.class));
  setIntegerIf(item, @selector(setTotalDiscCount:), field(t, @"discCount", NSNumber.class));
  NSNumber *duration = field(t, @"duration", NSNumber.class);
  if (duration && [item respondsToSelector:@selector(setDuration:)])
    ((void (*)(id, SEL, double))objc_msgSend)(item, @selector(setDuration:), duration.doubleValue);
  NSNumber *explicitItem = field(t, @"explicit", NSNumber.class);
  if (explicitItem && [item respondsToSelector:@selector(setExplicitItem:)])
    ((void (*)(id, SEL, BOOL))objc_msgSend)(item, @selector(setExplicitItem:), explicitItem.boolValue);
  if (current) {
    setRouteAndFormat(item, t);
    [item setElapsedTime:currentElapsed playbackRate:currentPlaying ? 1 : 0 timestamp:NSDate.timeIntervalSinceReferenceDate];
  }
  return item;
}

// Callers hold the lock.
static NSDictionary *queueEntry(NSString *identifier) {
  for (NSDictionary *entry in queue)
    if ([entry[@"id"] isEqualToString:identifier]) return entry;
  return nil;
}

// MediaPlayer asks the data source for the queue right away, on this thread,
// and throws if there's no current item; never let that reach Qobuz.
static void invalidateQueue(void) {
  @try {
    [[MPNowPlayingInfoCenter defaultCenter] invalidatePlaybackQueue];
  } @catch (NSException *e) {
    NSLog(@"qobuz-now-playing: invalidatePlaybackQueue: %@", e);
  }
}

#pragma mark - Queue data source

@interface QNP_CLASS : NSObject
@end

@implementation QNP_CLASS
- (NSString *)nowPlayingInfoCenter:(id)center contentItemIDForOffset:(NSInteger)offset {
  NSString *identifier = nil;
  [lock lock];
  GUARDED("contentItemIDForOffset", , {
    NSInteger i = queueCurrent + offset;
    if (queueCurrent >= 0 && i >= 0 && i < (NSInteger)queue.count) identifier = queue[i][@"id"];
  })
  [lock unlock];
  return identifier;
}

- (NSArray *)nowPlayingInfoCenter:(id)center
         contentItemIDsFromOffset:(NSInteger)from
                         toOffset:(NSInteger)to
                  nowPlayingIndex:(NSInteger *)nowPlayingIndex {
  NSMutableArray *ids = [NSMutableArray array];
  __block NSInteger index = -1;
  [lock lock];
  GUARDED("contentItemIDsFromOffset", , {
    if (queueCurrent >= 0)
      for (NSInteger offset = from; offset <= to; offset++) {
        NSInteger i = queueCurrent + offset;
        if (i < 0 || i >= (NSInteger)queue.count) continue;
        if (offset == 0) index = ids.count;
        [ids addObject:queue[i][@"id"]];
      }
  })
  [lock unlock];
  if (nowPlayingIndex) *nowPlayingIndex = index;
  return ids;
}

- (id)nowPlayingInfoCenter:(id)center contentItemForID:(NSString *)identifier {
  MPNowPlayingContentItem *item = nil;
  [lock lock];
  GUARDED("contentItemForID", item = nil, {
    item = contentItems[identifier];
    if (!item) {
      BOOL current = [identifier isEqualToString:currentId];
      NSDictionary *entry = queueEntry(identifier);
      if (current && currentTrack) item = makeContentItem(identifier, currentTrack, [entry[@"playable"] boolValue], YES);
      else if (entry) item = makeContentItem(identifier, entry[@"track"], [entry[@"playable"] boolValue], NO);
      if (item) contentItems[identifier] = item;
    }
  })
  [lock unlock];
  return item;
}
@end

#pragma mark - Commands

static void emitCommand(NSString *name, id value) {
  QNPCommandHandler handler = onCommand;
  if (handler) handler(name, value ?: @0);
}

static void addTarget(MPRemoteCommand *command, MPRemoteCommandHandlerStatus (^handler)(MPRemoteCommandEvent *)) {
  if (!command) return;
  id target = [command addTargetWithHandler:^MPRemoteCommandHandlerStatus(MPRemoteCommandEvent *e) {
    GUARDED("command", return MPRemoteCommandHandlerStatusCommandFailed, { return handler(e); })
  }];
  [targets addObject:@[ command, target ]];
}

static void wantEnabled(MPRemoteCommand *command, BOOL enabled) {
  if (!command) return;
  wantedEnabled[[NSValue valueWithNonretainedObject:command]] = @(enabled);
  if (command.enabled != enabled) command.enabled = enabled;
}

static NSArray<MPRemoteCommand *> *allCommands(void) {
  MPRemoteCommandCenter *rc = [MPRemoteCommandCenter sharedCommandCenter];
  NSMutableArray *commands = [NSMutableArray arrayWithArray:@[
    rc.playCommand, rc.pauseCommand, rc.togglePlayPauseCommand, rc.stopCommand, rc.nextTrackCommand,
    rc.previousTrackCommand, rc.changePlaybackPositionCommand, rc.skipForwardCommand, rc.skipBackwardCommand,
    rc.seekForwardCommand, rc.seekBackwardCommand, rc.changeShuffleModeCommand, rc.changeRepeatModeCommand,
    rc.likeCommand
  ]];
  for (NSString *name in @[ @"addNowPlayingItemToLibraryCommand", @"advanceShuffleModeCommand",
                            @"advanceRepeatModeCommand", @"playItemInQueueCommand" ])
    if ([rc respondsToSelector:NSSelectorFromString(name)]) [commands addObject:[rc valueForKey:name]];
  return commands;
}

static void registerCommands(void) {
  MPRemoteCommandCenter *rc = [MPRemoteCommandCenter sharedCommandCenter];
  MPRemoteCommandHandlerStatus ok = MPRemoteCommandHandlerStatusSuccess;
  NSDictionary<NSString *, NSString *> *simple = @{
    @"playCommand" : @"play",
    @"pauseCommand" : @"pause",
    @"togglePlayPauseCommand" : @"togglePlayPause",
    @"stopCommand" : @"pause",
    @"nextTrackCommand" : @"nextTrack",
    @"previousTrackCommand" : @"previousTrack",
    @"advanceShuffleModeCommand" : @"toggleShuffle",
    @"advanceRepeatModeCommand" : @"cycleRepeat",
  };
  [simple enumerateKeysAndObjectsUsingBlock:^(NSString *property, NSString *name, BOOL *stop) {
    if (![rc respondsToSelector:NSSelectorFromString(property)]) return;
    addTarget([rc valueForKey:property], ^(MPRemoteCommandEvent *e) {
      emitCommand(name, nil);
      return ok;
    });
  }];
  addTarget(rc.changePlaybackPositionCommand, ^(MPRemoteCommandEvent *e) {
    emitCommand(@"seekTo", @(((MPChangePlaybackPositionCommandEvent *)e).positionTime));
    return ok;
  });
  addTarget(rc.skipForwardCommand, ^(MPRemoteCommandEvent *e) {
    emitCommand(@"skip", @(((MPSkipIntervalCommandEvent *)e).interval ?: 15));
    return ok;
  });
  addTarget(rc.skipBackwardCommand, ^(MPRemoteCommandEvent *e) {
    emitCommand(@"skip", @(-(((MPSkipIntervalCommandEvent *)e).interval ?: 15)));
    return ok;
  });
  // A held media key: 1 when fast-forward or rewind begins, 0 when it ends.
  addTarget(rc.seekForwardCommand, ^(MPRemoteCommandEvent *e) {
    emitCommand(@"seekForward", @(((MPSeekCommandEvent *)e).type == MPSeekCommandEventTypeBeginSeeking));
    return ok;
  });
  addTarget(rc.seekBackwardCommand, ^(MPRemoteCommandEvent *e) {
    emitCommand(@"seekBackward", @(((MPSeekCommandEvent *)e).type == MPSeekCommandEventTypeBeginSeeking));
    return ok;
  });
  addTarget(rc.changeShuffleModeCommand, ^(MPRemoteCommandEvent *e) {
    emitCommand(@"shuffle", @(((MPChangeShuffleModeCommandEvent *)e).shuffleType != MPShuffleTypeOff));
    return ok;
  });
  addTarget(rc.changeRepeatModeCommand, ^(MPRemoteCommandEvent *e) {
    emitCommand(@"repeat", @(((MPChangeRepeatModeCommandEvent *)e).repeatType));
    return ok;
  });
  addTarget(rc.likeCommand, ^(MPRemoteCommandEvent *e) {
    emitCommand(@"favorite", @(!((MPFeedbackCommandEvent *)e).negative));
    return ok;
  });
  if ([rc respondsToSelector:@selector(addNowPlayingItemToLibraryCommand)])
    addTarget(rc.addNowPlayingItemToLibraryCommand, ^(MPRemoteCommandEvent *e) {
      emitCommand(@"favorite", @1);
      return ok;
    });
  if ([rc respondsToSelector:@selector(playItemInQueueCommand)])
    addTarget(rc.playItemInQueueCommand, ^(MPRemoteCommandEvent *e) {
      NSString *identifier = [e respondsToSelector:@selector(contentItemID)] ? e.contentItemID : nil;
      [lock lock];
      BOOL playable = identifier && [queueEntry(identifier)[@"playable"] boolValue];
      [lock unlock];
      if (!playable) return MPRemoteCommandHandlerStatusNoSuchContent;
      emitCommand(@"playItem", baseId(identifier));
      return ok;
    });
  rc.skipForwardCommand.preferredIntervals = @[ @15 ];
  rc.skipBackwardCommand.preferredIntervals = @[ @15 ];
  rc.likeCommand.localizedTitle = @"Favorite";
  rc.likeCommand.localizedShortTitle = @"Favorite";
}

// Chromium shares MPNowPlayingInfoCenter and MPRemoteCommandCenter with us and
// disables commands and resets the playback state when a page's media session
// ends. Put ours back if that happens.
static void reassert(void) {
  if (!started) return;
  MPNowPlayingInfoCenter *center = [MPNowPlayingInfoCenter defaultCenter];
  if (center.playbackState != wantedState) center.playbackState = wantedState;
  [wantedEnabled enumerateKeysAndObjectsUsingBlock:^(NSValue *key, NSNumber *enabled, BOOL *stop) {
    MPRemoteCommand *command = key.nonretainedObjectValue;
    if (command.enabled != enabled.boolValue) command.enabled = enabled.boolValue;
  }];
  if (attached && center.playbackQueueDataSource != dataSource) center.playbackQueueDataSource = dataSource;
}

#pragma mark - System output

static const AudioObjectPropertyAddress defaultOutputAddress = {
  kAudioHardwarePropertyDefaultOutputDevice, kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain};

static NSString *defaultOutputName(void) {
  AudioObjectID device = kAudioObjectUnknown;
  UInt32 size = sizeof device;
  if (AudioObjectGetPropertyData(kAudioObjectSystemObject, &defaultOutputAddress, 0, NULL, &size, &device) != noErr ||
      device == kAudioObjectUnknown)
    return nil;
  AudioObjectPropertyAddress nameAddress = {kAudioObjectPropertyName, kAudioObjectPropertyScopeGlobal,
                                            kAudioObjectPropertyElementMain};
  CFStringRef name = NULL;
  size = sizeof name;
  if (AudioObjectGetPropertyData(device, &nameAddress, 0, NULL, &size, &name) != noErr || !name) return nil;
  return CFBridgingRelease(name);
}

// Qobuz plays to the device chosen in Qobuz and ignores the macOS default, so
// switching outputs elsewhere (the menu bar, or apps like Vorssaint) wouldn't
// move it. Report each change, and the host switches Qobuz to match.
static void watchSystemOutput(void) {
  __block NSString *last = defaultOutputName();
  outputListener = ^(UInt32 count, const AudioObjectPropertyAddress *addresses) {
    GUARDED("systemOutput", , {
      NSString *name = defaultOutputName();
      if (name && ![name isEqualToString:last]) emitCommand(@"systemOutput", name);
      last = name;
    })
  };
  AudioObjectAddPropertyListenerBlock(kAudioObjectSystemObject, &defaultOutputAddress, dispatch_get_main_queue(),
                                      outputListener);
}

#pragma mark - Core API

void qnpStart(QNPCommandHandler handler) {
  if (started) return;
  started = YES;
  onCommand = [handler copy];
  lock = [NSLock new];
  contentItems = [NSMutableDictionary dictionary];
  targets = [NSMutableArray array];
  wantedEnabled = [NSMutableDictionary dictionary];
  registerCommands();
  for (MPRemoteCommand *command in allCommands()) wantEnabled(command, NO);
  dataSource = [QNP_CLASS new];
  watchSystemOutput();
  guardTimer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, dispatch_get_main_queue());
  dispatch_source_set_timer(guardTimer, dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC), NSEC_PER_SEC, NSEC_PER_SEC / 4);
  dispatch_source_set_event_handler(guardTimer, ^{ GUARDED("reassert", , { reassert(); }) });
  dispatch_resume(guardTimer);
}

// Builds MediaPlayer's queue from the page's, around the current track
// (callers hold the lock).
static void placeCurrent(void) {
  NSMutableArray<NSDictionary *> *placed = [pageQueue ?: @[] mutableCopy];
  NSInteger index = -1;
  if (pageCurrent >= 0 && pageCurrent < (NSInteger)placed.count && [placed[pageCurrent][@"id"] isEqualToString:currentBase])
    index = pageCurrent;
  else
    for (NSUInteger i = 0; i < placed.count; i++)
      if ([placed[i][@"id"] isEqualToString:currentBase]) index = i;
  if (index < 0) {
    // A track that isn't in the queue (yet) is a queue of one.
    placed = [NSMutableArray arrayWithObject:@{@"id" : currentBase, @"track" : currentTrack, @"playable" : @NO}];
    index = 0;
  }
  NSMutableDictionary *entry = [placed[index] mutableCopy];
  entry[@"id"] = currentId;
  placed[index] = entry;
  queue = placed;
  queueCurrent = index;
  // Items MediaPlayer already has stay as they are; only the current one is
  // kept, as the others may have new details.
  MPNowPlayingContentItem *item = contentItems[currentId];
  [contentItems removeAllObjects];
  if (item) contentItems[currentId] = item;
}

// state: the current track and player:
//   title, artist, album, albumArtist, composer, genre, isrc (strings),
//   trackNumber, trackCount, discNumber, discCount, duration (s), explicit,
//   itemId (the page's id for it in the queue), elapsed (s), playing,
//   shuffle, repeat (MPRepeatType), favorite, canNext, canPlayItems,
//   queueIndex, queueCount, output (name of the audio output),
//   sampleRate (Hz), bitDepth, codec (FourCC), tier, and
//   artwork (NSData; NSNull removes it, absent keeps it) with artworkId.
// nil clears Now Playing.
void qnpUpdate(NSDictionary *state) {
  if (!started) return;
  MPNowPlayingInfoCenter *center = [MPNowPlayingInfoCenter defaultCenter];
  MPRemoteCommandCenter *rc = [MPRemoteCommandCenter sharedCommandCenter];
  if (!state) {
    for (MPRemoteCommand *command in allCommands()) wantEnabled(command, NO);
    // Detach rather than offer an empty queue, which MediaPlayer can't take.
    attached = NO;
    center.playbackQueueDataSource = nil;
    [lock lock];
    pageQueue = queue = nil;
    pageCurrent = queueCurrent = -1;
    currentBase = currentId = nil;
    currentTrack = nil;
    currentArtwork = nil;
    [contentItems removeAllObjects];
    [lock unlock];
    wantedState = MPNowPlayingPlaybackStateStopped;
    center.playbackState = wantedState;
    return;
  }
  BOOL playing = [state[@"playing"] boolValue];
  BOOL shuffle = [state[@"shuffle"] boolValue];
  MPRepeatType repeat = [state[@"repeat"] integerValue];
  BOOL favorite = [state[@"favorite"] boolValue];
  id artwork = state[@"artwork"];
  NSDictionary *artworkKeys = currentArtwork;
  if ([artwork isKindOfClass:NSData.class]) artworkKeys = artworkInfo(artwork, state[@"artworkId"]);
  else if (artwork == NSNull.null) artworkKeys = nil;
  NSMutableDictionary *track = [state mutableCopy];
  [track removeObjectsForKeys:@[ @"elapsed", @"playing", @"artwork", @"artworkId", @"canNext", @"canPlayItems" ]];
  if (artworkKeys) track[@"artworkId"] = artworkKeys[MR("ArtworkIdentifier")];
  NSString *base = field(state, @"itemId", NSString.class) ?: @"current";
  double elapsed = [state[@"elapsed"] doubleValue];

  BOOL republish = NO;
  [lock lock];
  currentElapsed = elapsed;
  currentPlaying = playing;
  currentArtwork = artworkKeys;
  if (![track isEqualToDictionary:currentTrack] || ![base isEqualToString:currentBase]) {
    currentTrack = [track copy];
    currentBase = base;
    currentId = [NSString stringWithFormat:@"%@#%lu", base, (unsigned long)++revision];
    placeCurrent();
    republish = YES;
  }
  MPNowPlayingContentItem *item = republish ? nil : contentItems[currentId];
  [lock unlock];
  // Position and play state change through the item MediaPlayer already has.
  if (item) [item setElapsedTime:elapsed playbackRate:playing ? 1 : 0 timestamp:NSDate.timeIntervalSinceReferenceDate];

  for (MPRemoteCommand *command in allCommands()) {
    BOOL enabled = YES;
    if (command == rc.nextTrackCommand) enabled = [state[@"canNext"] boolValue];
    if ([rc respondsToSelector:@selector(playItemInQueueCommand)] && command == rc.playItemInQueueCommand)
      enabled = [state[@"canPlayItems"] boolValue];
    wantEnabled(command, enabled);
  }
  rc.changeShuffleModeCommand.currentShuffleType = shuffle ? MPShuffleTypeItems : MPShuffleTypeOff;
  rc.changeRepeatModeCommand.currentRepeatType = repeat;
  rc.likeCommand.active = favorite;
  if ([rc respondsToSelector:@selector(addNowPlayingItemToLibraryCommand)])
    rc.addNowPlayingItemToLibraryCommand.active = favorite;

  wantedState = playing ? MPNowPlayingPlaybackStatePlaying : MPNowPlayingPlaybackStatePaused;
  center.playbackState = wantedState;
  if (!attached) {
    attached = YES;
    center.playbackQueueDataSource = dataSource;
  }
  if (republish) invalidateQueue();
}

// items: {id, title, artist, album, duration, artwork (NSData), artworkId,
// playable}, in play order; current: the index of the current track.
void qnpSetQueue(NSArray<NSDictionary *> *items, NSInteger current) {
  if (!started) return;
  NSMutableArray *entries = [NSMutableArray arrayWithCapacity:items.count];
  for (NSDictionary *item in items) {
    if (![item isKindOfClass:NSDictionary.class]) continue;
    NSString *identifier = field(item, @"id", NSString.class);
    if (identifier)
      [entries addObject:@{@"id" : identifier, @"track" : item, @"playable" : @([item[@"playable"] boolValue])}];
  }
  [lock lock];
  pageQueue = entries;
  pageCurrent = current;
  BOOL ready = currentId != nil;
  if (ready) placeCurrent();
  [lock unlock];
  if (ready && attached) invalidateQueue();
}

void qnpStop(void) {
  if (!started) return;
  started = NO;
  if (guardTimer) dispatch_source_cancel(guardTimer);
  guardTimer = nil;
  if (outputListener)
    AudioObjectRemovePropertyListenerBlock(kAudioObjectSystemObject, &defaultOutputAddress, dispatch_get_main_queue(),
                                           outputListener);
  outputListener = nil;
  for (NSArray *pair in targets) {
    MPRemoteCommand *command = pair[0];
    [command removeTarget:pair[1]];
    command.enabled = NO;
  }
  [targets removeAllObjects];
  [wantedEnabled removeAllObjects];
  MPNowPlayingInfoCenter *center = [MPNowPlayingInfoCenter defaultCenter];
  if (center.playbackQueueDataSource == dataSource) center.playbackQueueDataSource = nil;
  attached = NO;
  dataSource = nil;
  center.playbackState = MPNowPlayingPlaybackStateStopped;
  [lock lock];
  pageQueue = queue = nil;
  pageCurrent = queueCurrent = -1;
  currentBase = currentId = nil;
  currentTrack = nil;
  currentArtwork = nil;
  [contentItems removeAllObjects];
  [lock unlock];
  onCommand = nil;
}

#ifndef QNP_NO_NAPI
#pragma mark - Node-API glue (ABI-stable functions, resolved from the host process)

typedef struct napi_env__ *napi_env;
typedef struct napi_value__ *napi_value;
typedef struct napi_callback_info__ *napi_callback_info;
typedef struct napi_threadsafe_function__ *napi_threadsafe_function;
typedef int napi_status;
typedef enum { napi_undefined, napi_null, napi_boolean, napi_number, napi_string, napi_symbol, napi_object, napi_function } napi_valuetype;
typedef napi_value (*napi_callback)(napi_env, napi_callback_info);
typedef void (*napi_finalize)(napi_env, void *, void *);
typedef void (*napi_threadsafe_function_call_js)(napi_env, napi_value, void *, void *);

extern napi_status napi_create_function(napi_env, const char *, size_t, napi_callback, void *, napi_value *);
extern napi_status napi_set_named_property(napi_env, napi_value, const char *, napi_value);
extern napi_status napi_get_cb_info(napi_env, napi_callback_info, size_t *, napi_value *, napi_value *, void **);
extern napi_status napi_typeof(napi_env, napi_value, napi_valuetype *);
extern napi_status napi_get_value_string_utf8(napi_env, napi_value, char *, size_t, size_t *);
extern napi_status napi_get_value_double(napi_env, napi_value, double *);
extern napi_status napi_get_value_bool(napi_env, napi_value, bool *);
extern napi_status napi_get_property_names(napi_env, napi_value, napi_value *);
extern napi_status napi_get_property(napi_env, napi_value, napi_value, napi_value *);
extern napi_status napi_is_array(napi_env, napi_value, bool *);
extern napi_status napi_get_array_length(napi_env, napi_value, uint32_t *);
extern napi_status napi_get_element(napi_env, napi_value, uint32_t, napi_value *);
extern napi_status napi_is_buffer(napi_env, napi_value, bool *);
extern napi_status napi_get_buffer_info(napi_env, napi_value, void **, size_t *);
extern napi_status napi_create_string_utf8(napi_env, const char *, size_t, napi_value *);
extern napi_status napi_create_double(napi_env, double, napi_value *);
extern napi_status napi_get_undefined(napi_env, napi_value *);
extern napi_status napi_call_function(napi_env, napi_value, napi_value, size_t, const napi_value *, napi_value *);
extern napi_status napi_create_threadsafe_function(napi_env, napi_value, napi_value, napi_value, size_t, size_t, void *,
                                                   napi_finalize, void *, napi_threadsafe_function_call_js,
                                                   napi_threadsafe_function *);
extern napi_status napi_call_threadsafe_function(napi_threadsafe_function, void *, int);
extern napi_status napi_release_threadsafe_function(napi_threadsafe_function, int);
extern napi_status napi_unref_threadsafe_function(napi_env, napi_threadsafe_function);
extern napi_status napi_throw_error(napi_env, const char *, const char *);

static napi_threadsafe_function tsfn;

static NSString *jsString(napi_env env, napi_value v) {
  size_t len = 0;
  if (napi_get_value_string_utf8(env, v, NULL, 0, &len) != 0) return nil;
  NSMutableData *buf = [NSMutableData dataWithLength:len + 1];
  napi_get_value_string_utf8(env, v, buf.mutableBytes, len + 1, &len);
  return [[NSString alloc] initWithBytes:buf.bytes length:len encoding:NSUTF8StringEncoding];
}

// Converts JS values into the plist types MediaRemote can archive: strings,
// numbers, Buffers (NSData), null (NSNull), plain objects and arrays.
static id fromJs(napi_env env, napi_value v, int depth) {
  napi_valuetype type;
  if (depth > 4 || napi_typeof(env, v, &type) != 0) return nil;
  switch (type) {
    case napi_null: return NSNull.null;
    case napi_boolean: {
      bool b;
      napi_get_value_bool(env, v, &b);
      return @(b);
    }
    case napi_number: {
      double d;
      napi_get_value_double(env, v, &d);
      return isfinite(d) ? @(d) : nil;
    }
    case napi_string: return jsString(env, v);
    case napi_object: {
      bool flag = false;
      if (napi_is_buffer(env, v, &flag) == 0 && flag) {
        void *data;
        size_t len;
        napi_get_buffer_info(env, v, &data, &len);
        return [NSData dataWithBytes:data length:len];
      }
      if (napi_is_array(env, v, &flag) == 0 && flag) {
        uint32_t n = 0;
        napi_get_array_length(env, v, &n);
        NSMutableArray *array = [NSMutableArray arrayWithCapacity:n];
        for (uint32_t i = 0; i < n; i++) {
          napi_value el;
          napi_get_element(env, v, i, &el);
          id value = fromJs(env, el, depth + 1);
          if (value) [array addObject:value];
        }
        return array;
      }
      napi_value keys;
      uint32_t n = 0;
      napi_get_property_names(env, v, &keys);
      napi_get_array_length(env, keys, &n);
      NSMutableDictionary *dict = [NSMutableDictionary dictionaryWithCapacity:n];
      for (uint32_t i = 0; i < n; i++) {
        napi_value key, value;
        napi_get_element(env, keys, i, &key);
        napi_get_property(env, v, key, &value);
        NSString *name = jsString(env, key);
        id converted = fromJs(env, value, depth + 1);
        if (name && converted) dict[name] = converted;
      }
      return dict;
    }
    default: return nil;
  }
}

typedef struct {
  char *name;
  char *string;
  double number;
} CommandMsg;

static void callJs(napi_env env, napi_value fn, void *context, void *data) {
  CommandMsg *msg = data;
  if (env && fn) {
    napi_value argv[2], undefined;
    napi_get_undefined(env, &undefined);
    napi_create_string_utf8(env, msg->name, SIZE_MAX, &argv[0]);
    if (msg->string) napi_create_string_utf8(env, msg->string, SIZE_MAX, &argv[1]);
    else napi_create_double(env, msg->number, &argv[1]);
    napi_call_function(env, undefined, fn, 2, argv, NULL);
  }
  free(msg->name);
  free(msg->string);
  free(msg);
}

static napi_value Start(napi_env env, napi_callback_info info) {
  size_t argc = 1;
  napi_value argv[1];
  napi_valuetype type;
  napi_get_cb_info(env, info, &argc, argv, NULL, NULL);
  if (argc < 1 || napi_typeof(env, argv[0], &type) != 0 || type != napi_function) {
    napi_throw_error(env, NULL, "start(onCommand) needs a function");
    return NULL;
  }
  if (started) return NULL;
  napi_value name;
  napi_create_string_utf8(env, "qobuzNowPlaying", SIZE_MAX, &name);
  napi_create_threadsafe_function(env, argv[0], NULL, name, 0, 1, NULL, NULL, NULL, callJs, &tsfn);
  // Don't keep Node's event loop alive on our account.
  napi_unref_threadsafe_function(env, tsfn);
  napi_threadsafe_function fn = tsfn;
  GUARDED("start", , { qnpStart(^(NSString *command, id value) {
    CommandMsg *msg = calloc(1, sizeof(CommandMsg));
    msg->name = strdup(command.UTF8String);
    if ([value isKindOfClass:NSString.class]) msg->string = strdup([value UTF8String]);
    else msg->number = [value doubleValue];
    if (napi_call_threadsafe_function(fn, msg, 0) != 0) {
      free(msg->name);
      free(msg->string);
      free(msg);
    }
  }); })
  return NULL;
}

static napi_value Update(napi_env env, napi_callback_info info) {
  size_t argc = 1;
  napi_value argv[1];
  napi_get_cb_info(env, info, &argc, argv, NULL, NULL);
  GUARDED("update", , {
    id state = argc ? fromJs(env, argv[0], 0) : nil;
    qnpUpdate([state isKindOfClass:NSDictionary.class] ? state : nil);
  })
  return NULL;
}

static napi_value SetQueue(napi_env env, napi_callback_info info) {
  size_t argc = 2;
  napi_value argv[2];
  napi_get_cb_info(env, info, &argc, argv, NULL, NULL);
  id items = argc > 0 ? fromJs(env, argv[0], 0) : nil;
  double current = -1;
  if (argc > 1) napi_get_value_double(env, argv[1], &current);
  if (![items isKindOfClass:NSArray.class]) {
    napi_throw_error(env, NULL, "setQueue(items, currentIndex)");
    return NULL;
  }
  GUARDED("setQueue", , { qnpSetQueue(items, isfinite(current) ? (NSInteger)current : -1); })
  return NULL;
}

static napi_value Stop(napi_env env, napi_callback_info info) {
  GUARDED("stop", , { qnpStop(); })
  if (tsfn) napi_release_threadsafe_function(tsfn, 0);
  tsfn = NULL;
  return NULL;
}

__attribute__((visibility("default"))) int32_t node_api_module_get_api_version_v1(void) { return 8; }

__attribute__((visibility("default"))) napi_value napi_register_module_v1(napi_env env, napi_value exports) {
  struct {
    const char *name;
    napi_callback cb;
  } fns[] = {{"start", Start}, {"update", Update}, {"setQueue", SetQueue}, {"stop", Stop}};
  for (size_t i = 0; i < sizeof fns / sizeof *fns; i++) {
    napi_value fn;
    napi_create_function(env, fns[i].name, SIZE_MAX, fns[i].cb, NULL, &fn);
    napi_set_named_property(env, exports, fns[i].name, fn);
  }
  return exports;
}
#endif
