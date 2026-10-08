/*
 * Installed as <wine>/lib/wine/x86_64-unix/wine, the loader Wine execs for
 * every new Windows process; the original host is kept beside it as
 * wine-host. The process whose executable (argv[1]) contains
 * YAAGL_GAME_HOST_MATCH (the game executable name) runs YAAGL_GAME_HOST_EXE
 * instead (the copy of wine-host inside the registered game .app, so macOS
 * can enable Game Mode for it), with YAAGL_GAME_HOST_DYLIB injected. Every
 * other process runs wine-host unchanged.
 *
 * argv[0] is set to this file's resolved path; the host looks for ntdll.so
 * next to its own executable first and falls back to argv[0]'s directory.
 */
#include <limits.h>
#include <mach-o/dyld.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

int main(int argc, char **argv) {
  char self[PATH_MAX], real[PATH_MAX], host[PATH_MAX];
  uint32_t size = sizeof self;
  if (_NSGetExecutablePath(self, &size) || !realpath(self, real)) {
    fprintf(stderr, "wine-shim: cannot resolve own path\n");
    return 127;
  }
  argv[0] = real;

  const char *gameHost = getenv("YAAGL_GAME_HOST_EXE");
  const char *match = getenv("YAAGL_GAME_HOST_MATCH");
  const char *dylib = getenv("YAAGL_GAME_HOST_DYLIB");
  if (argc > 1 && gameHost && *gameHost && match && *match && strcasestr(argv[1], match) &&
      access(gameHost, X_OK) == 0) {
    if (dylib && *dylib) setenv("DYLD_INSERT_LIBRARIES", dylib, 1);
    execv(gameHost, argv);
  }
  /* Processes the game starts inherit its environment; keep them clean. */
  const char *inserted = getenv("DYLD_INSERT_LIBRARIES");
  if (dylib && inserted && !strcmp(inserted, dylib)) unsetenv("DYLD_INSERT_LIBRARIES");

  snprintf(host, sizeof host, "%s-host", real);
  execv(host, argv);
  perror("wine-shim: exec wine-host");
  return 127;
}
