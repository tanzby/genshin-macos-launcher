/*
 * Development helper run inside the game's Wine prefix by yaagl-diag:
 * turns the camera with relative mouse motion through SendInput, the same
 * path real mouse input takes into the game.
 * Usage: turner.exe <seconds> <dx per step> <step ms>
 */
#include <stdlib.h>
#include <windows.h>

int main(int argc, char **argv) {
  double seconds = argc > 1 ? atof(argv[1]) : 10;
  int dx = argc > 2 ? atoi(argv[2]) : 20;
  int stepMs = argc > 3 ? atoi(argv[3]) : 8;
  DWORD end = GetTickCount() + (DWORD)(seconds * 1000);
  while (GetTickCount() < end) {
    INPUT in = {0};
    in.type = INPUT_MOUSE;
    in.mi.dx = dx;
    in.mi.dwFlags = MOUSEEVENTF_MOVE;
    SendInput(1, &in, sizeof in);
    Sleep(stepMs);
  }
  return 0;
}
