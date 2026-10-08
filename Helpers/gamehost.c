/*
 * yaagl-gamehost: injected into the game's Wine process (wine-shim.c sets
 * DYLD_INSERT_LIBRARIES for it only) to put the game window into a native
 * macOS full-screen Space, which is what macOS Game Mode requires. Wine's mac driver only offers native full screen
 * for resizable windows, and the game's window is not. In full screen the
 * window covers the notch area too (see hookFullScreenFrame, hookMinLevel).
 *
 * Links only libSystem: the Wine host must not load AppKit early, so all
 * Objective-C access goes through the runtime, resolved after winemac.so
 * (which brings AppKit in) is loaded.
 *
 * It also answers lookups of this Mac's own host name locally (see
 * gamehost_getaddrinfo).
 *
 * Env: YAAGL_GAMEHOST_LOG=<file>  optional log file
 *      YAAGL_GAMEHOST_DEV=<mode>   load yaagl-gamehost-dev.dylib (see there)
 */
#include <dispatch/dispatch.h>
#include <dlfcn.h>
#include <fcntl.h>
#include <mach-o/dyld.h>
#include <arpa/inet.h>
#include <ifaddrs.h>
#include <net/if.h>
#include <netdb.h>
#include <netinet/in.h>
#include <strings.h>
#include <time.h>
#include <stdarg.h>
#include <stdbool.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

typedef void *id;
typedef void *SEL;
typedef void *Class;
typedef void *Method;
typedef void (*IMP)(void);
typedef struct { double x, y, w, h; } Rect;
typedef struct { double top, left, bottom, right; } Insets;

#define FULLSCREEN_PRIMARY (1UL << 7)
#define FULLSCREEN_AUXILIARY (1UL << 8)
#define STYLE_FULLSCREEN (1UL << 14)

static Class (*getClass)(const char *);
static SEL (*selName)(const char *);
static Method (*instanceMethod)(Class, SEL);
static IMP (*setImpl)(Method, IMP);
static IMP (*classImpl)(Class, SEL);
static signed char (*addMethod)(Class, SEL, IMP, const char *);
static const char *(*typeEncoding)(Method);
static void *msgSend, *msgSendStret;
static id *nsApp;

static int logFd = -1;
/* Log a line; exported for gamehost-dev.dylib. */
__attribute__((visibility("default"))) void gamehost_say(const char *fmt, ...) {
  if (logFd < 0) return;
  char buf[512];
  va_list ap;
  va_start(ap, fmt);
  int n = vsnprintf(buf, sizeof buf - 1, fmt, ap);
  va_end(ap);
  if (n > (int)sizeof buf - 2) n = sizeof buf - 2;
  buf[n++] = '\n';
  write(logFd, buf, n);
}
#define say gamehost_say

/* YAAGL_GAMEHOST_DEV: load the development companion (frame statistics,
 * scripted input, screenshots) next to this library. */
static void startDev(id win) {
  if (!getenv("YAAGL_GAMEHOST_DEV")) return;
  Dl_info info;
  char path[1024];
  if (!dladdr((void *)startDev, &info) || !info.dli_fname) return;
  snprintf(path, sizeof path, "%s", info.dli_fname);
  char *slash = strrchr(path, '/');
  if (!slash) return;
  snprintf(slash + 1, path + sizeof path - slash - 1, "yaagl-gamehost-dev.dylib");
  void *dev = dlopen(path, RTLD_NOW);
  void (*start)(void *) = dev ? dlsym(dev, "gamehost_dev_start") : NULL;
  if (start) start(win);
  else say("gamehost: dev companion unavailable: %s", dlerror());
}

static id sendId(id o, const char *s) { return ((id(*)(id, SEL))msgSend)(o, selName(s)); }
static unsigned long sendUL(id o, const char *s) {
  return ((unsigned long (*)(id, SEL))msgSend)(o, selName(s));
}
static bool sendBool(id o, const char *s) {
  return ((signed char (*)(id, SEL))msgSend)(o, selName(s));
}
static Rect sendRect(id o, const char *s) {
  return ((Rect(*)(id, SEL))msgSendStret)(o, selName(s));
}
static id sendIdAt(id array, unsigned long i) {
  return ((id(*)(id, SEL, unsigned long))msgSend)(array, selName("objectAtIndex:"), i);
}
/* Allow (and keep) native full screen for the window. */
static void setPrimaryFullscreen(id win, unsigned long behavior) {
  ((void (*)(id, SEL, unsigned long))msgSend)(
      win, selName("setCollectionBehavior:"), (behavior | FULLSCREEN_PRIMARY) & ~FULLSCREEN_AUXILIARY);
}

static Class wineWindowClass;

/* Ask gamepolicyd (via the private GamePolicy framework) how it classifies
 * this process: Game Mode needs isIdentifiedGame and isGameFullscreen. */
static id policyMonitor;
static bool policyWatched;
static void logPolicy(const char *what, id info, const char *key) {
  SEL sel = selName(key);
  if (!((signed char (*)(id, SEL, SEL))msgSend)(info, selName("respondsToSelector:"), sel)) return;
  say("gamepolicy: %s %s=%d", what, key, (int)((signed char (*)(id, SEL))msgSend)(info, sel));
}
static void watchGamePolicy(void) {
  policyWatched = true;
  if ( !dlopen("/System/Library/PrivateFrameworks/GamePolicy.framework/Versions/A/GamePolicy", RTLD_NOW))
    return;
  Class monitorClass = getClass("GPProcessMonitor");
  if (!monitorClass) return;
  policyMonitor = sendId(sendId(monitorClass, "monitorForCurrentProcess"), "retain");
  void (^update)(id, id) = ^(id monitor, id info) {
    (void)monitor;
    logPolicy("process", info, "isIdentifiedGame");
  };
  void (^transient)(id, id) = ^(id monitor, id info) {
    (void)monitor;
    logPolicy("transient", info, "isGameFullscreen");
  };
  ((void (*)(id, SEL, void *))msgSend)(policyMonitor, selName("setUpdateHandler:"), (void *)update);
  ((void (*)(id, SEL, void *))msgSend)(policyMonitor, selName("setTransientUpdateHandler:"), (void *)transient);
}
static id fullscreenTarget; /* window we already sent to full screen */

static bool isGameWindow(id win) {
  if (!win || !sendBool(win, "isVisible") || sendId(win, "parentWindow")) return false;
  if (!((signed char (*)(id, SEL, Class))msgSend)(win, selName("isKindOfClass:"), wineWindowClass))
    return false;
  id screen = sendId(win, "screen");
  if (!screen) return false;
  Rect f = sendRect(win, "frame"), s = sendRect(screen, "frame");
  return f.w >= s.w * 0.5 && f.h >= s.h * 0.5;
}

/* winemac recomputes the behavior on every style change and would drop the
 * full-screen-primary flag (and leave full screen) for non-resizable windows. */
static IMP origAdjust;
static void hookAdjust(id self, SEL _cmd, unsigned long behavior) {
  if (isGameWindow(self)) {
    setPrimaryFullscreen(self, behavior);
    return;
  }
  ((void (*)(id, SEL, unsigned long))origAdjust)(self, _cmd, behavior);
}

/* AppKit lays out a native full-screen window below the camera housing (the
 * screen's safe area). These private NSWindow getters give that frame; the
 * game window gets the whole screen instead. The tile getters are needed too,
 * or the window falls back below the notch when it is ordered front again.
 * A split-view tile is narrower than the screen and is left alone. */
static struct {
  const char *name;
  SEL sel;
  IMP orig;
} frameHooks[] = {{.name = "_frameForFullScreenMode"},
                  {.name = "_tileFrameForFullScreen"},
                  {.name = "_fullScreenTileFrame"},
                  {.name = "_visibleTileFrameForFullScreen"}};
static Rect hookFullScreenFrame(id self, SEL _cmd) {
  unsigned long i = 0;
  while (frameHooks[i].sel != _cmd) i++;
  Rect frame = ((Rect(*)(id, SEL))frameHooks[i].orig)(self, _cmd);
  id screen = self == fullscreenTarget ? sendId(self, "screen") : NULL;
  if (!screen) return frame;
  Rect s = sendRect(screen, "frame");
  return frame.w < s.w ? frame : s;
}

/* On a Mac with a notch the menu bar window (level 24) stays on screen over
 * the top of a full-screen Space, drawn black, and so covers the top of the
 * game. winemac decides window levels in minimumLevelForActive:; while the app
 * is active and the window is in full screen on such a screen, the game window
 * goes above the menu bar. winemac's adjustWindowLevels never puts a window
 * below one behind it, so windows the game orders in front stay above it, and
 * when another app (e.g. the game's browser process) becomes active, winemac
 * lowers the game window again. */
#define MAIN_MENU_LEVEL 24
static bool aboveMenuBar(id win) {
  if (win != fullscreenTarget || !(sendUL(win, "styleMask") & STYLE_FULLSCREEN)) return false;
  id screen = sendId(win, "screen");
  return screen && ((Insets(*)(id, SEL))msgSendStret)(screen, selName("safeAreaInsets")).top > 0;
}
static IMP origMinLevel;
static long hookMinLevel(id self, SEL _cmd, signed char active) {
  long level = ((long (*)(id, SEL, signed char))origMinLevel)(self, _cmd, active);
  return active && level <= MAIN_MENU_LEVEL && aboveMenuBar(self) ? MAIN_MENU_LEVEL + 1 : level;
}
/* winemac recomputes the levels when windows are ordered or the app is
 * (de)activated, not when the window enters or leaves full screen, so ask it
 * then. Until the full-screen transition is over, the window is not on the
 * current Space and winemac skips it, so raising is retried: every tick for
 * a few ticks, then every LEVEL_BACKOFF ticks. */
#define LEVEL_RETRIES 10
#define LEVEL_BACKOFF 10
static bool wantAbove;
static int levelRetries;
static void updateLevel(id app) {
  if (!origMinLevel) return;
  bool want = sendBool(app, "isActive") && aboveMenuBar(fullscreenTarget);
  bool above = (long)sendUL(fullscreenTarget, "level") > MAIN_MENU_LEVEL;
  if (want != wantAbove) say("gamehost: full-screen window %s the menu bar", want ? "goes above" : "goes back below");
  if (want != wantAbove || above) levelRetries = 0;
  bool retry = want && !above && (levelRetries++ < LEVEL_RETRIES || levelRetries % LEVEL_BACKOFF == 0);
  if (retry || (!want && wantAbove)) {
    id controller = sendId(getClass("WineApplicationController"), "sharedController");
    ((void (*)(id, SEL))msgSend)(controller, selName("adjustWindowLevels"));
  }
  wantAbove = want;
}

/* After the game window is closed the process should exit; if it is still
 * around this long, it is stuck in shutdown and only keeps Wine alive. The
 * launcher cannot time this out itself: its wait on steam.exe only returns
 * once the game process is gone. */
#define STUCK_EXIT_SECONDS 15
static double goneSince;

static double now(void) {
  struct timespec t;
  clock_gettime(CLOCK_MONOTONIC, &t);
  return t.tv_sec + t.tv_nsec / 1e9;
}

static bool targetPresent(id windows, unsigned long n) {
  for (unsigned long i = 0; i < n; i++) {
    id win = sendIdAt(windows, i);
    if (win == fullscreenTarget)
      return sendBool(win, "isVisible") || sendBool(win, "isMiniaturized");
  }
  return false;
}

static void tick(void *ctx) {
  (void)ctx;
  id app = *nsApp;
  if (!app) return;
  id windows = sendId(app, "windows");
  unsigned long n = sendUL(windows, "count");
  if (fullscreenTarget) {
    if (targetPresent(windows, n)) {
      goneSince = 0;
      updateLevel(app);
      return; /* in full screen, or the user chose to leave it */
    }
    if (!goneSince) {
      goneSince = now();
      say("gamehost: game window closed");
    } else if (now() - goneSince > STUCK_EXIT_SECONDS) {
      say("gamehost: still running %ds after the window closed, exiting", STUCK_EXIT_SECONDS);
      _exit(0);
    }
  }
  for (unsigned long i = 0; i < n; i++) {
    id win = sendIdAt(windows, i);
    if (!isGameWindow(win)) continue;
    if (sendUL(win, "styleMask") & STYLE_FULLSCREEN) return;
    if (!policyWatched) {
      /* Subscribe before the transition so the full-screen update is seen;
       * toggle on the next tick. */
      watchGamePolicy();
      return;
    }
    fullscreenTarget = win;
    goneSince = 0; /* a recreated game window replaces the closed one */
    setPrimaryFullscreen(win, sendUL(win, "collectionBehavior"));
    ((void (*)(id, SEL, signed char))msgSend)(app, selName("activateIgnoringOtherApps:"), 1);
    /* Call NSWindow's implementation: WineWindow's override refuses for
     * windows Wine does not consider resizable. */
    IMP toggle = classImpl(getClass("NSWindow"), selName("toggleFullScreen:"));
    ((void (*)(id, SEL, id))toggle)(win, selName("toggleFullScreen:"), NULL);
    Rect f = sendRect(win, "frame");
    say("gamehost: toggled native full screen for window %p (%.0fx%.0f)", win, f.w, f.h);
    startDev(win);
    return;
  }
}

/* The game resolves this Mac's own host name (<name>.local). That is an mDNS
 * query, i.e. Local Network access, which macOS silently holds for a bundled
 * app without that permission until it fails ~35s later. Answer it from the
 * interface addresses instead; every other name goes to the real resolver. */
static char hostName[256]; /* set in init */
static bool isOwnHostName(const char *node) {
  if (!node || !*hostName) return false;
  if (!strcasecmp(node, hostName)) return true;
  size_t n = strlen(hostName);
  if (n > 6 && !strcasecmp(hostName + n - 6, ".local"))
    return strlen(node) == n - 6 && !strncasecmp(node, hostName, n - 6);
  return false;
}

static void localAddress(char *buf, size_t size) {
  snprintf(buf, size, "127.0.0.1");
  struct ifaddrs *list, *ifa;
  if (getifaddrs(&list)) return;
  for (ifa = list; ifa; ifa = ifa->ifa_next) {
    if (!ifa->ifa_addr || ifa->ifa_addr->sa_family != AF_INET) continue;
    if (!(ifa->ifa_flags & IFF_UP) || (ifa->ifa_flags & IFF_LOOPBACK)) continue;
    inet_ntop(AF_INET, &((struct sockaddr_in *)ifa->ifa_addr)->sin_addr, buf, size);
    break;
  }
  freeifaddrs(list);
}

static int gamehost_getaddrinfo(const char *node, const char *service, const struct addrinfo *hints,
                                struct addrinfo **res) {
  if (isOwnHostName(node) && (!hints || hints->ai_family != AF_INET6)) {
    char addr[INET_ADDRSTRLEN];
    struct addrinfo numeric = hints ? *hints : (struct addrinfo){0};
    localAddress(addr, sizeof addr);
    numeric.ai_family = AF_INET;
    numeric.ai_flags = (numeric.ai_flags | AI_NUMERICHOST) & ~AI_CANONNAME;
    int ret = getaddrinfo(addr, service, &numeric, res);
    say("gamehost: answered own host name %s with %s (%d)", node, addr, ret);
    return ret;
  }
  return getaddrinfo(node, service, hints, res);
}
__attribute__((used, section("__DATA,__interpose"))) static struct {
  const void *replacement, *original;
} interposers[] = {{(const void *)gamehost_getaddrinfo, (const void *)getaddrinfo}};

static bool installed;
static void install(void) {
  getClass = dlsym(RTLD_DEFAULT, "objc_getClass");
  selName = dlsym(RTLD_DEFAULT, "sel_registerName");
  instanceMethod = dlsym(RTLD_DEFAULT, "class_getInstanceMethod");
  setImpl = dlsym(RTLD_DEFAULT, "method_setImplementation");
  classImpl = dlsym(RTLD_DEFAULT, "class_getMethodImplementation");
  addMethod = dlsym(RTLD_DEFAULT, "class_addMethod");
  typeEncoding = dlsym(RTLD_DEFAULT, "method_getTypeEncoding");
  msgSend = dlsym(RTLD_DEFAULT, "objc_msgSend");
  msgSendStret = dlsym(RTLD_DEFAULT, "objc_msgSend_stret");
  nsApp = dlsym(RTLD_DEFAULT, "NSApp");
  if (!getClass || !msgSend || !msgSendStret || !nsApp || !addMethod || !typeEncoding) {
    say("gamehost: objc runtime not available");
    return;
  }
  wineWindowClass = getClass("WineWindow");
  if (!wineWindowClass) {
    say("gamehost: WineWindow class not found");
    return;
  }
  Method m = instanceMethod(wineWindowClass, selName("adjustFullScreenBehavior:"));
  if (m) origAdjust = setImpl(m, (IMP)hookAdjust);
  Method ml = instanceMethod(wineWindowClass, selName("minimumLevelForActive:"));
  if (ml) origMinLevel = setImpl(ml, (IMP)hookMinLevel);
  else say("gamehost: minimumLevelForActive: missing");
  for (unsigned long i = 0; i < sizeof frameHooks / sizeof *frameHooks; i++) {
    SEL sel = frameHooks[i].sel = selName(frameHooks[i].name);
    Method f = instanceMethod(wineWindowClass, sel);
    if (!f) {
      say("gamehost: %s missing", frameHooks[i].name);
      continue;
    }
    /* Override in WineWindow, leaving NSWindow's implementation to other windows. */
    frameHooks[i].orig = classImpl(wineWindowClass, sel);
    if (!addMethod(wineWindowClass, sel, (IMP)hookFullScreenFrame, typeEncoding(f)))
      frameHooks[i].orig = setImpl(f, (IMP)hookFullScreenFrame);
  }
  dispatch_source_t timer =
      dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, dispatch_get_main_queue());
  dispatch_source_set_timer(timer, dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC),
                            NSEC_PER_SEC / 2, NSEC_PER_SEC / 10);
  dispatch_source_set_event_handler_f(timer, tick);
  dispatch_resume(timer);
  say("gamehost: installed in pid %d (adjust hook %s)", getpid(), m ? "on" : "missing");
}

static void onImage(const struct mach_header *mh, intptr_t slide) {
  (void)slide;
  if (installed) return;
  Dl_info info;
  if (!dladdr(mh, &info) || !info.dli_fname) return;
  const char *name = strrchr(info.dli_fname, '/');
  if (!name || strcmp(name, "/winemac.so")) return;
  installed = true;
  /* Defer: the image is not fully initialised inside this callback. */
  dispatch_async_f(dispatch_get_main_queue(), NULL, (void (*)(void *))install);
}

__attribute__((constructor)) static void init(void) {
  const char *path = getenv("YAAGL_GAMEHOST_LOG");
  if (path && *path) logFd = open(path, O_WRONLY | O_CREAT | O_APPEND, 0644);
  if (gethostname(hostName, sizeof hostName)) *hostName = 0;
  hostName[sizeof hostName - 1] = 0;
  _dyld_register_func_for_add_image(onImage);
}
