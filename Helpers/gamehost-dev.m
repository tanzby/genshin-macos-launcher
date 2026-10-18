/*
 * Development-only companion of gamehost.dylib, loaded (dlopen) into the game
 * process when GENSHIN_LAUNCHER_GAMEHOST_DEV is set. Used by scripts/dev/genshin-launcher-diag to
 * measure the game deterministically without screen capture permissions:
 *
 *  - frame statistics: every -[CAMetalLayer nextDrawable] is timestamped and
 *    intervals are summarised per phase (p50/p99/max, hitches > 50 ms);
 *  - a scripted session (GENSHIN_LAUNCHER_GAMEHOST_DEV=autoplay): click into the
 *    window for a minute to enter the game, then time an idle and a
 *    camera-turn phase (length GENSHIN_LAUNCHER_GAMEHOST_TURN seconds)
 *    (the turn itself is driven by turner.exe via SendInput);
 *  - a movement measurement (GENSHIN_LAUNCHER_GAMEHOST_DEV=measure): enter the game
 *    like autoplay, then collect the presented times of the main game layer while
 *    W or S is held (by a person or a synthetic key event); on release they are
 *    summarised like the frame statistics, plus drawables never presented;
 *  - screenshots: the previous drawable is copied to a PNG
 *    (GENSHIN_LAUNCHER_GAMEHOST_SHOT_DIR), at the end of each phase;
 *  - a screen check (GENSHIN_LAUNCHER_GAMEHOST_DEV=screen): enter the game, then save
 *    the drawable after each step (see screenCheck). genshin-launcher-diag captures the
 *    screen at each "shot:" line and compares the two.
 */
#import <AppKit/AppKit.h>
#import <Carbon/Carbon.h>
#import <ImageIO/ImageIO.h>
#import <Metal/Metal.h>
#import <QuartzCore/QuartzCore.h>
#import <objc/runtime.h>
#import <dlfcn.h>
#import <mach/mach.h>
#import <mach/mach_vm.h>
#import <os/lock.h>
#import <pthread.h>
#import <stdatomic.h>
#import <fcntl.h>
#import <unistd.h>

void gamehost_say(const char *fmt, ...);
bool gamehost_debug(void);
/* The companion only runs in dev tools: its output is Debug mode output. */
#define gamehost_trace(...) do { if (gamehost_debug()) gamehost_say(__VA_ARGS__); } while (0)

#define MAX_FRAMES 20000
static double frameTimes[MAX_FRAMES];
static int frameCount;
static _Atomic bool stallWatch; /* true while a movement key is held (stall sampler) */
static os_unfair_lock frameLock = OS_UNFAIR_LOCK_INIT;
static id<CAMetalDrawable> lastDrawable;
static NSString *pendingShot;
static int shotArmedAt = -1; /* frame index once drawables are blittable */

static int compareDouble(const void *a, const void *b) {
  double x = *(const double *)a, y = *(const double *)b;
  return x < y ? -1 : x > y;
}

/* Interval statistics of n >= 3 ascending timestamps (seconds). */
typedef struct { double fps, p50, p99, max; int hitches; } IntervalStats;
static IntervalStats intervalStats(const double *t, int n) {
  int m = n - 1, hitches = 0;
  double *d = malloc(sizeof(double) * m);
  for (int i = 0; i < m; i++) {
    d[i] = (t[i + 1] - t[i]) * 1000;
    if (d[i] > 50) hitches++;
  }
  qsort(d, m, sizeof(double), compareDouble);
  IntervalStats st = {m / (t[m] - t[0]), d[m / 2], d[(int)(m * 0.99)], d[m - 1], hitches};
  free(d);
  return st;
}

/* One line per interval > 50 ms: the presented time on the mach clock (CACurrentMediaTime) and on the wall
 * clock, so scripts/diag/fps-measure can line it up with cache writes and other samples. */
static void logHitches(const char *phase, const double *t, int n) {
  double nowMach = CACurrentMediaTime(), nowWall = [NSDate date].timeIntervalSince1970;
  for (int i = 0; i + 1 < n; i++) {
    double dur = (t[i + 1] - t[i]) * 1000;
    if (dur > 50)
      gamehost_trace("hitch: phase=%s t=%.3f wall=%.3f dur=%.1fms", phase, t[i + 1], nowWall - (nowMach - t[i + 1]), dur);
  }
}

static void resetFrames(void) {
  os_unfair_lock_lock(&frameLock);
  frameCount = 0;
  os_unfair_lock_unlock(&frameLock);
}

static void reportFrames(const char *phase) {
  os_unfair_lock_lock(&frameLock);
  int n = frameCount;
  double *t = malloc(sizeof(double) * (n > 1 ? n : 1));
  memcpy(t, frameTimes, sizeof(double) * n);
  os_unfair_lock_unlock(&frameLock);
  if (n < 3) {
    gamehost_trace("frames: phase=%s frames=%d (no data)", phase, n);
    free(t);
    return;
  }
  IntervalStats st = intervalStats(t, n);
  gamehost_trace("frames: phase=%s frames=%d fps=%.1f p50=%.1fms p99=%.1fms max=%.1fms hitches50=%d",
               phase, n, st.fps, st.p50, st.p99, st.max, st.hitches);
  free(t);
}

static void saveShot(id<CAMetalDrawable> drawable, NSString *path) {
  id<MTLTexture> tex = drawable.texture;
  if (!tex) return;
  // Drawables are BGRA8 here; other (e.g. 10-bit) formats are not handled.
  if (tex.pixelFormat != MTLPixelFormatBGRA8Unorm && tex.pixelFormat != MTLPixelFormatBGRA8Unorm_sRGB) {
    gamehost_trace("shot: unsupported pixel format %lu", (unsigned long)tex.pixelFormat);
    return;
  }
  NSUInteger w = tex.width, h = tex.height, bpr = w * 4;
  id<MTLDevice> dev = tex.device;
  id<MTLBuffer> buf = [dev newBufferWithLength:bpr * h options:MTLResourceStorageModeShared];
  id<MTLCommandQueue> q = [dev newCommandQueue];
  id<MTLCommandBuffer> cb = [q commandBuffer];
  id<MTLBlitCommandEncoder> blit = [cb blitCommandEncoder];
  [blit copyFromTexture:tex sourceSlice:0 sourceLevel:0 sourceOrigin:MTLOriginMake(0, 0, 0)
             sourceSize:MTLSizeMake(w, h, 1) toBuffer:buf destinationOffset:0
 destinationBytesPerRow:bpr destinationBytesPerImage:bpr * h];
  [blit endEncoding];
  [cb commit];
  [cb waitUntilCompleted];
  CGColorSpaceRef cs = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
  CGContextRef ctx = CGBitmapContextCreate(buf.contents, w, h, 8, bpr, cs,
                                           kCGImageAlphaNoneSkipFirst | kCGBitmapByteOrder32Little);
  CGImageRef img = CGBitmapContextCreateImage(ctx);
  CGImageDestinationRef dst = CGImageDestinationCreateWithURL(
      (__bridge CFURLRef)[NSURL fileURLWithPath:path], CFSTR("public.png"), 1, NULL);
  CGImageDestinationAddImage(dst, img, NULL);
  bool ok = CGImageDestinationFinalize(dst);
  CFRelease(dst);
  CGImageRelease(img);
  CGContextRelease(ctx);
  CGColorSpaceRelease(cs);
  gamehost_trace("shot: %s %lux%lu %s", path.UTF8String, (unsigned long)w, (unsigned long)h, ok ? "ok" : "failed");
}

/* Measure mode: presented times of the largest layer while a movement key is down. */
static double presentTimes[MAX_FRAMES];
static int presentCount, droppedCount;
static bool measureMode, measuring;
static CAMetalLayer *mainLayer;
static double mainArea;

static void summarise(const char *phase, double *t, int n, int dropped, CGSize size) {
  if (n < 3) {
    gamehost_trace("present: phase=%s presented=%d dropped=%d (no data)", phase, n, dropped);
    return;
  }
  qsort(t, n, sizeof(double), compareDouble); /* handlers may arrive out of order */
  IntervalStats st = intervalStats(t, n);
  logHitches(phase, t, n);
  /* Pacing: how many intervals fall on each display tick count (8.3 ms = one 120 Hz refresh). */
  int bucket[6] = {0}; /* <12.5, <20.8, <29.2, <37.5, <50, >=50 ms */
  for (int i = 0; i + 1 < n; i++) {
    double ms = (t[i + 1] - t[i]) * 1000;
    bucket[ms < 12.5 ? 0 : ms < 20.8 ? 1 : ms < 29.2 ? 2 : ms < 37.5 ? 3 : ms < 50 ? 4 : 5]++;
  }
  gamehost_trace("pacing: phase=%s ms<12.5=%d <20.8=%d <29.2=%d <37.5=%d <50=%d >=50=%d", phase, bucket[0], bucket[1],
                 bucket[2], bucket[3], bucket[4], bucket[5]);
  gamehost_trace("present: phase=%s size=%.0fx%.0f seconds=%.1f presented=%d dropped=%d fps=%.1f p50=%.1fms "
               "p99=%.1fms max=%.1fms hitches50=%d",
               phase, size.width, size.height, t[n - 1] - t[0], n, dropped, st.fps, st.p50, st.p99, st.max,
               st.hitches);
}

static void trackPresent(CAMetalLayer *layer, id<CAMetalDrawable> drawable) {
  CGSize size = layer.drawableSize;
  os_unfair_lock_lock(&frameLock);
  if (size.width * size.height > mainArea) {
    mainArea = size.width * size.height;
    mainLayer = layer;
  }
  bool track = measuring && layer == mainLayer;
  os_unfair_lock_unlock(&frameLock);
  if (!track) return;
  [drawable addPresentedHandler:^(id<MTLDrawable> presented) {
    CFTimeInterval at = presented.presentedTime;
    os_unfair_lock_lock(&frameLock);
    if (measuring) {
      if (at == 0) droppedCount++;
      else if (presentCount < MAX_FRAMES) presentTimes[presentCount++] = at;
    }
    os_unfair_lock_unlock(&frameLock);
  }];
}

static void setMeasuring(const char *key, bool on) {
  os_unfair_lock_lock(&frameLock);
  int n = presentCount, dropped = droppedCount;
  double *t = malloc(sizeof(double) * (n > 0 ? n : 1));
  memcpy(t, presentTimes, sizeof(double) * n);
  CGSize size = mainLayer ? mainLayer.drawableSize : CGSizeZero;
  measuring = on;
  stallWatch = on;
  presentCount = droppedCount = 0;
  os_unfair_lock_unlock(&frameLock);
  gamehost_trace("measure: %s %s", key, on ? "down" : "up");
  if (!on) summarise(key, t, n, dropped, size);
  free(t);
}

/* Stall sampler (measure mode). Frame intervals are only known after the fact, too late for `sample` to see
 * the stall, so a watchdog thread notices while it lasts: when the render thread has not entered nextDrawable
 * for STALL_GAP seconds it suspends each thread in turn, walks its frame-pointer chain and writes the stack to
 * GENSHIN_LAUNCHER_GAMEHOST_STALLS (a few captures per stall). `nd:` lines time the nextDrawable call itself,
 * which separates drawable-acquisition blocking from a stall upstream of it. */
#define STALL_GAP 0.045
#define STALL_CAPTURES 8
#define MAX_THREADS 128
#define MAX_DEPTH 14
static int stallFd = -1;
static _Atomic double lastEnter;
static _Atomic bool inNextDrawable;
static _Atomic mach_port_t renderThread;
static uint64_t stackPCs[MAX_THREADS][MAX_DEPTH];
static int stackDepth[MAX_THREADS];
static thread_act_t stackThread[MAX_THREADS];

static bool readWord(uint64_t address, uint64_t *out) {
  mach_vm_size_t got = 0;
  return mach_vm_read_overwrite(mach_task_self(), address, 8, (mach_vm_address_t)out, &got) == KERN_SUCCESS && got == 8;
}

/* Suspends, reads and resumes each thread without allocating: a suspended thread may hold the malloc lock. */
static int captureStacks(void) {
  thread_act_array_t list;
  mach_msg_type_number_t count;
  if (task_threads(mach_task_self(), &list, &count) != KERN_SUCCESS) return 0;
  thread_act_t me = mach_thread_self();
  int m = 0;
  for (mach_msg_type_number_t i = 0; i < count && m < MAX_THREADS; i++) {
    if (list[i] == me || thread_suspend(list[i]) != KERN_SUCCESS) continue;
    x86_thread_state64_t st;
    mach_msg_type_number_t n = x86_THREAD_STATE64_COUNT;
    int depth = 0;
    if (thread_get_state(list[i], x86_THREAD_STATE64, (thread_state_t)&st, &n) == KERN_SUCCESS) {
      stackPCs[m][depth++] = st.__rip;
      uint64_t fp = st.__rbp;
      while (depth < MAX_DEPTH && fp && !(fp & 7)) {
        uint64_t next, ret;
        if (!readWord(fp, &next) || !readWord(fp + 8, &ret) || !ret) break;
        stackPCs[m][depth++] = ret;
        if (next <= fp) break;
        fp = next;
      }
    }
    thread_resume(list[i]);
    stackDepth[m] = depth;
    stackThread[m++] = list[i];
  }
  mach_port_deallocate(mach_task_self(), me);
  vm_deallocate(mach_task_self(), (vm_address_t)list, count * sizeof(thread_act_t));
  return m;
}

static void writeStacks(int stall, int capture, int m, double wall, double gap) {
  mach_port_t render = renderThread;
  for (int i = 0; i < m; i++) {
    char name[64] = "";
    pthread_t pt = pthread_from_mach_thread_np(stackThread[i]);
    if (pt) pthread_getname_np(pt, name, sizeof name);
    NSMutableString *line = [NSMutableString string];
    for (int d = 0; d < stackDepth[i]; d++) {
      Dl_info info;
      uint64_t pc = stackPCs[i][d];
      if (dladdr((void *)pc, &info) && info.dli_fname) {
        const char *base = strrchr(info.dli_fname, '/');
        base = base ? base + 1 : info.dli_fname;
        if (info.dli_sname) [line appendFormat:@" %s!%s+%llu", base, info.dli_sname, pc - (uint64_t)info.dli_saddr];
        else [line appendFormat:@" %s+0x%llx", base, pc - (uint64_t)info.dli_fbase];
      } else {
        [line appendFormat:@" 0x%llx", pc];
      }
    }
    dprintf(stallFd, "stack: stall=%d cap=%d wall=%.3f gap=%.0fms thread=%u%s name=\"%s\" frames:%s\n", stall,
            capture, wall, gap * 1000, stackThread[i], stackThread[i] == render ? "*" : "", name, line.UTF8String);
    mach_port_deallocate(mach_task_self(), stackThread[i]);
  }
}

static void *watchdog(void *unused) {
  pthread_setname_np("gamehost-watchdog");
  int stall = 0, captures = 0;
  bool in = false;
  for (;;) {
    usleep(3000);
    double gap = CACurrentMediaTime() - lastEnter;
    if (!stallWatch || lastEnter == 0 || gap < STALL_GAP) {
      in = false;
      continue;
    }
    double wall = [NSDate date].timeIntervalSince1970;
    if (!in) {
      in = true;
      captures = 0;
      stall++;
      dprintf(stallFd, "stall: id=%d wall=%.3f gap=%.0fms in_nextDrawable=%d\n", stall, wall, gap * 1000,
              (int)inNextDrawable);
    }
    if (captures < STALL_CAPTURES) {
      int m = captureStacks();
      writeStacks(stall, captures++, m, wall, gap);
      usleep(6000);
    }
  }
  return NULL;
}

static void startStallSampler(void) {
  const char *path = getenv("GENSHIN_LAUNCHER_GAMEHOST_STALLS");
  if (!path || !*path) return;
  stallFd = open(path, O_WRONLY | O_CREAT | O_APPEND, 0644);
  if (stallFd < 0) return;
  pthread_t t;
  pthread_create(&t, NULL, watchdog, NULL);
  pthread_detach(t);
}

static IMP origNextDrawable;
static id hookNextDrawable(CAMetalLayer *self, SEL _cmd) {
  // Copy the previous (already presented) frame before the next one starts.
  NSString *shot = nil;
  id<CAMetalDrawable> previous = nil;
  os_unfair_lock_lock(&frameLock);
  if (frameCount < MAX_FRAMES) frameTimes[frameCount++] = CACurrentMediaTime();
  bool makeWritable = false;
  if (pendingShot && shotArmedAt < 0) {
    shotArmedAt = frameCount;
    makeWritable = true;
  } else if (pendingShot && lastDrawable && frameCount >= shotArmedAt + 2) {
    shot = pendingShot;
    pendingShot = nil;
    shotArmedAt = -1;
    previous = lastDrawable;
  }
  os_unfair_lock_unlock(&frameLock);
  if (shot) saveShot(previous, shot);
  // Drawables are framebuffer-only by default; make them blittable only for a
  // requested screenshot so normal frame timing is unaffected.
  if (makeWritable) self.framebufferOnly = NO;
  bool main = stallFd >= 0 && self == mainLayer;
  double entered = CACurrentMediaTime();
  if (main) {
    lastEnter = entered;
    renderThread = mach_thread_self();
    mach_port_deallocate(mach_task_self(), renderThread);
    inNextDrawable = true;
  }
  id<CAMetalDrawable> d = ((id (*)(id, SEL))origNextDrawable)(self, _cmd);
  if (main) {
    inNextDrawable = false;
    double took = CACurrentMediaTime() - entered;
    if (took > 0.010 && stallWatch)
      dprintf(stallFd, "nd: wall=%.3f dur=%.1fms\n", [NSDate date].timeIntervalSince1970, took * 1000);
  }
  if (d && measureMode) trackPresent(self, d);
  os_unfair_lock_lock(&frameLock);
  lastDrawable = d;
  os_unfair_lock_unlock(&frameLock);
  return d;
}

static void requestShot(const char *name) {
  const char *dir = getenv("GENSHIN_LAUNCHER_GAMEHOST_SHOT_DIR");
  if (!dir || !*dir) return;
  os_unfair_lock_lock(&frameLock);
  pendingShot = [NSString stringWithFormat:@"%s/%s.png", dir, name];
  os_unfair_lock_unlock(&frameLock);
}

static NSWindow *gameWindow;

static void postMouse(NSEventType type) {
  NSRect f = gameWindow.contentView.bounds;
  NSPoint p = NSMakePoint(NSMidX(f), NSMidY(f) * 0.9);
  NSEvent *e = [NSEvent mouseEventWithType:type location:p modifierFlags:0
                                 timestamp:NSProcessInfo.processInfo.systemUptime
                              windowNumber:gameWindow.windowNumber context:nil eventNumber:0
                                clickCount:1 pressure:type == NSEventTypeLeftMouseDown ? 1 : 0];
  [NSApp postEvent:e atStart:NO];
}

static void after(double seconds, dispatch_block_t block) {
  dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(seconds * NSEC_PER_SEC)),
                 dispatch_get_main_queue(), block);
}

static void click(void) {
  postMouse(NSEventTypeLeftMouseDown);
  after(0.08, ^{ postMouse(NSEventTypeLeftMouseUp); });
}

/* Click into the window every 5 s for ENTER_SECONDS: enters the game from the
 * title screen and dismisses popups. */
#define ENTER_SECONDS 60
static void enterGame(void) {
  for (double t = 3; t < ENTER_SECONDS; t += 5) after(t, ^{ click(); });
}

/* Autoplay: enters the game, waits SETTLE seconds, then measures IDLE
 * seconds standing still and the turn phase. */
static void autoplay(void) {
  const double settle = 20, idle = 10;
  const char *turnEnv = getenv("GENSHIN_LAUNCHER_GAMEHOST_TURN");
  double turn = turnEnv && *turnEnv ? atof(turnEnv) : 12;
  enterGame();
  double t0 = ENTER_SECONDS + settle;
  after(t0, ^{
    gamehost_trace("autoplay: idle phase");
    resetFrames();
  });
  after(t0 + idle, ^{
    reportFrames("idle");
    requestShot("idle");
  });
  // Start measuring after the screenshot (its GPU readback stalls a frame).
  after(t0 + idle + 1.5, ^{
    gamehost_trace("autoplay: turn phase");
    resetFrames();
  });
  // The camera is turned from inside Wine by turner.exe (SendInput), started
  // by genshin-launcher-diag when it sees the "turn phase" line.
  after(t0 + idle + 1.5 + turn, ^{
    reportFrames("turn");
    requestShot("turn");
    gamehost_trace("autoplay: done");
  });
}

static void postKey(unsigned short code, NSString *ch, bool down) {
  NSEvent *e = [NSEvent keyEventWithType:down ? NSEventTypeKeyDown : NSEventTypeKeyUp location:NSZeroPoint
                           modifierFlags:0 timestamp:NSProcessInfo.processInfo.systemUptime
                            windowNumber:gameWindow.windowNumber context:nil characters:ch
             charactersIgnoringModifiers:ch isARepeat:NO keyCode:code];
  [NSApp postEvent:e atStart:NO];
}

/* strip: the screen's top safe-area inset in pixels; display: its number for
 * `screencapture -D`. */
static void logWindow(const char *step) {
  NSRect f = gameWindow.frame;
  NSScreen *screen = gameWindow.screen;
  CGDirectDisplayID screenID = [screen.deviceDescription[@"NSScreenNumber"] unsignedIntValue], ids[16];
  uint32_t n = 0, display = 1;
  CGGetActiveDisplayList(16, ids, &n);
  for (uint32_t i = 0; i < n; i++)
    if (ids[i] == screenID) display = i + 1;
  gamehost_trace("screen: step=%s fullscreen=%d active=%d level=%ld frame=%.0fx%.0f strip=%.0f display=%u", step,
               (int)!!(gameWindow.styleMask & NSWindowStyleMaskFullScreen), (int)NSApp.isActive,
               (long)gameWindow.level, f.size.width, f.size.height,
               screen.safeAreaInsets.top * screen.backingScaleFactor, display);
}

/* The control step keeps the window below the menu bar, which must show up
 * as "covered" on a Mac with a notch. The hook is only in place during it. */
static IMP origSetLevel;
static void hookSetLevel(NSWindow *self, SEL _cmd, NSInteger level) {
  if (self == gameWindow) level = NSNormalWindowLevel;
  ((void (*)(id, SEL, NSInteger))origSetLevel)(self, _cmd, level);
}

/* Each step acts, waits `settle` seconds for the picture, then saves the
 * drawable. */
static void screenCheck(void) {
  Method setLevel = class_getInstanceMethod([NSWindow class], @selector(setLevel:));
  enterGame();
  struct {
    double settle;
    const char *name;
    dispatch_block_t act;
  } steps[] = {
      {0, "world", ^{}},
      {6, "after-hide", ^{
         [NSApp hide:nil];
         after(4, ^{
           [NSApp unhide:nil];
           [NSApp activateIgnoringOtherApps:YES];
           [gameWindow makeKeyAndOrderFront:nil];
         });
       }},
      {6, "after-walk", ^{
         postKey(13, @"w", true);
         after(2, ^{ postKey(13, @"w", false); });
       }},
      {6, "after-attack", ^{
         for (int i = 0; i < 3; i++) after(i * 0.6, ^{ click(); });
       }},
      {6, "control-below-menu-bar", ^{
         origSetLevel = method_setImplementation(setLevel, (IMP)hookSetLevel);
         [gameWindow setLevel:NSNormalWindowLevel];
       }},
      {6, "restored", ^{ method_setImplementation(setLevel, origSetLevel); }},
  };
  double t = ENTER_SECONDS + 15;
  for (unsigned long i = 0; i < sizeof steps / sizeof *steps; i++) {
    const char *name = steps[i].name;
    after(t, steps[i].act);
    after(t + steps[i].settle, ^{
      logWindow(name);
      requestShot(name);
    });
    t += steps[i].settle + 2;
  }
  /* Last, as the game stays in the background after it (an app in the
   * background may not activate itself): genshin-launcher-diag opens a window of
   * another Wine program at "open-other", checks at the step line that it is
   * on screen and the game below it, then closes it. */
  after(t, ^{ gamehost_trace("screen: open-other"); });
  after(t + 6, ^{ logWindow("other-window"); });
  after(t + 7, ^{ gamehost_trace("screen: done"); });
}

/* Polls W and S in the combined session state, which includes synthetic events. */
static void measure(void) {
  static const char *active;
  static dispatch_source_t timer; /* kept for the life of the process */
  timer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, dispatch_get_main_queue());
  dispatch_source_set_timer(timer, DISPATCH_TIME_NOW, 20 * NSEC_PER_MSEC, 5 * NSEC_PER_MSEC);
  dispatch_source_set_event_handler(timer, ^{
    bool w = CGEventSourceKeyState(kCGEventSourceStateCombinedSessionState, kVK_ANSI_W);
    bool s = CGEventSourceKeyState(kCGEventSourceStateCombinedSessionState, kVK_ANSI_S);
    const char *down = w ? "W" : s ? "S" : NULL;
    if (down == active) return;
    if (active) setMeasuring(active, false);
    if (down) setMeasuring(down, true);
    active = down;
  });
  dispatch_resume(timer);
  enterGame();
  after(ENTER_SECONDS, ^{ gamehost_trace("measure: ready"); });
}

void gamehost_dev_start(void *window) {
  static bool started;
  if (started) return;
  started = true;
  gameWindow = (__bridge NSWindow *)window;
  Method m = class_getInstanceMethod([CAMetalLayer class], @selector(nextDrawable));
  if (m) origNextDrawable = method_setImplementation(m, (IMP)hookNextDrawable);
  gamehost_trace("dev: frame stats %s", m ? "on" : "unavailable");
  const char *mode = getenv("GENSHIN_LAUNCHER_GAMEHOST_DEV");
  if (mode && !strcmp(mode, "autoplay")) autoplay();
  if (mode && !strcmp(mode, "screen")) screenCheck();
  measureMode = mode && !strcmp(mode, "measure");
  if (measureMode) startStallSampler();
  if (measureMode) measure();
}
