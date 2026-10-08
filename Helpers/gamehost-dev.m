/*
 * Development-only companion of gamehost.dylib, loaded (dlopen) into the game
 * process when YAAGL_GAMEHOST_DEV is set. Used by scripts/dev/yaagl-diag to
 * measure the game deterministically without screen capture permissions:
 *
 *  - frame statistics: every -[CAMetalLayer nextDrawable] is timestamped and
 *    intervals are summarised per phase (p50/p99/max, hitches > 50 ms);
 *  - a scripted session (YAAGL_GAMEHOST_DEV=autoplay): click into the
 *    window for a minute to enter the game, then time an idle and a
 *    camera-turn phase (length YAAGL_GAMEHOST_TURN seconds)
 *    (the turn itself is driven by turner.exe via SendInput);
 *  - screenshots: the previous drawable is copied to a PNG
 *    (YAAGL_GAMEHOST_SHOT_DIR), at the end of each phase;
 *  - a screen check (YAAGL_GAMEHOST_DEV=screen): enter the game, then save
 *    the drawable after each step (see screenCheck). yaagl-diag captures the
 *    screen at each "shot:" line and compares the two.
 */
#import <AppKit/AppKit.h>
#import <ImageIO/ImageIO.h>
#import <Metal/Metal.h>
#import <QuartzCore/QuartzCore.h>
#import <objc/runtime.h>
#import <os/lock.h>

void gamehost_say(const char *fmt, ...);

#define MAX_FRAMES 20000
static double frameTimes[MAX_FRAMES];
static int frameCount;
static os_unfair_lock frameLock = OS_UNFAIR_LOCK_INIT;
static id<CAMetalDrawable> lastDrawable;
static NSString *pendingShot;
static int shotArmedAt = -1; /* frame index once drawables are blittable */

static int compareDouble(const void *a, const void *b) {
  double x = *(const double *)a, y = *(const double *)b;
  return x < y ? -1 : x > y;
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
    gamehost_say("frames: phase=%s frames=%d (no data)", phase, n);
    free(t);
    return;
  }
  int m = n - 1, hitches = 0;
  double *d = malloc(sizeof(double) * m), sum = 0;
  for (int i = 0; i < m; i++) {
    d[i] = (t[i + 1] - t[i]) * 1000;
    sum += d[i];
    if (d[i] > 50) hitches++;
  }
  qsort(d, m, sizeof(double), compareDouble);
  gamehost_say("frames: phase=%s frames=%d fps=%.1f p50=%.1fms p99=%.1fms max=%.1fms hitches50=%d",
               phase, n, m / (sum / 1000), d[m / 2], d[(int)(m * 0.99)], d[m - 1], hitches);
  free(d);
  free(t);
}

static void saveShot(id<CAMetalDrawable> drawable, NSString *path) {
  id<MTLTexture> tex = drawable.texture;
  if (!tex) return;
  // Drawables are BGRA8 here; other (e.g. 10-bit) formats are not handled.
  if (tex.pixelFormat != MTLPixelFormatBGRA8Unorm && tex.pixelFormat != MTLPixelFormatBGRA8Unorm_sRGB) {
    gamehost_say("shot: unsupported pixel format %lu", (unsigned long)tex.pixelFormat);
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
  gamehost_say("shot: %s %lux%lu %s", path.UTF8String, (unsigned long)w, (unsigned long)h, ok ? "ok" : "failed");
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
  id<CAMetalDrawable> d = ((id (*)(id, SEL))origNextDrawable)(self, _cmd);
  os_unfair_lock_lock(&frameLock);
  lastDrawable = d;
  os_unfair_lock_unlock(&frameLock);
  return d;
}

static void requestShot(const char *name) {
  const char *dir = getenv("YAAGL_GAMEHOST_SHOT_DIR");
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
  const char *turnEnv = getenv("YAAGL_GAMEHOST_TURN");
  double turn = turnEnv && *turnEnv ? atof(turnEnv) : 12;
  enterGame();
  double t0 = ENTER_SECONDS + settle;
  after(t0, ^{
    gamehost_say("autoplay: idle phase");
    resetFrames();
  });
  after(t0 + idle, ^{
    reportFrames("idle");
    requestShot("idle");
  });
  // Start measuring after the screenshot (its GPU readback stalls a frame).
  after(t0 + idle + 1.5, ^{
    gamehost_say("autoplay: turn phase");
    resetFrames();
  });
  // The camera is turned from inside Wine by turner.exe (SendInput), started
  // by yaagl-diag when it sees the "turn phase" line.
  after(t0 + idle + 1.5 + turn, ^{
    reportFrames("turn");
    requestShot("turn");
    gamehost_say("autoplay: done");
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
  gamehost_say("screen: step=%s fullscreen=%d active=%d level=%ld frame=%.0fx%.0f strip=%.0f display=%u", step,
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
   * background may not activate itself): yaagl-diag opens a window of
   * another Wine program at "open-other", checks at the step line that it is
   * on screen and the game below it, then closes it. */
  after(t, ^{ gamehost_say("screen: open-other"); });
  after(t + 6, ^{ logWindow("other-window"); });
  after(t + 7, ^{ gamehost_say("screen: done"); });
}

void gamehost_dev_start(void *window) {
  static bool started;
  if (started) return;
  started = true;
  gameWindow = (__bridge NSWindow *)window;
  Method m = class_getInstanceMethod([CAMetalLayer class], @selector(nextDrawable));
  if (m) origNextDrawable = method_setImplementation(m, (IMP)hookNextDrawable);
  gamehost_say("dev: frame stats %s", m ? "on" : "unavailable");
  const char *mode = getenv("YAAGL_GAMEHOST_DEV");
  if (mode && !strcmp(mode, "autoplay")) autoplay();
  if (mode && !strcmp(mode, "screen")) screenCheck();
}
