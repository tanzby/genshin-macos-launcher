/*
 * Frame-rate unlock, part of genshin-launcher-gamehost.dylib. The game's PE image
 * lives in this same process (Wine maps it next to us), so the cap is lifted
 * from inside: find the frame-rate variable the engine reads, then keep
 * writing the target into it, because the game writes its own setting (30/60)
 * back on settings changes and scene loads. Only a data word is written; code
 * is never patched.
 *
 * The signature is the one from winTEuser/Genshin_StarRail_fps_unlocker
 * (MIT, see THIRD_PARTY_NOTICES.md): `movd xmm1, [rip+disp32]` followed by
 * `xorps xmm0, xmm0; cvtdq2ps xmm1, xmm1` in the game's .text, whose operand
 * is the variable.
 *
 * Env: GENSHIN_LAUNCHER_FPS_TARGET=<n>  frame-rate cap to force (1...1000)
 */
#include <dispatch/dispatch.h>
#include <mach/mach.h>
#include <mach/mach_vm.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>

void gamehost_say(const char *fmt, ...);
#define say gamehost_say

/* Where Wine maps the game executable when nothing is in the way. */
#define PREFERRED_BASE 0x140000000ULL
/* The image appears a few seconds after the process starts; its .text is scanned at most SCAN_TRIES times. */
#define FIND_SECONDS 120
#define SCAN_TRIES 30

typedef struct {
  uint64_t base;
  uint64_t textStart, textSize; /* absolute */
  uint64_t dataStart, dataSize;
} Image;

static int32_t target;
static uint64_t fpsVar;
static int lastSeen = 0x7fffffff;
static int findAttempts, scanAttempts;
static Image image; /* image.base == 0 until found */
static dispatch_source_t timer;

static void giveUp(const char *why) {
  say("fps: %s, unlock off", why);
  dispatch_source_cancel(timer);
}

/* Reads that fail instead of faulting: the address may be unmapped or guarded. */
static bool readMemory(uint64_t address, void *out, size_t size) {
  mach_vm_size_t got = 0;
  return mach_vm_read_overwrite(mach_task_self(), address, size, (mach_vm_address_t)out, &got) == KERN_SUCCESS &&
         got == size;
}

/* A 64-bit PE image at `base` with an `il2cpp` section is the game. */
static bool parseImage(uint64_t base, Image *image) {
  uint8_t header[0x1000];
  if (!readMemory(base, header, sizeof header) || header[0] != 'M' || header[1] != 'Z') return false;
  uint32_t pe;
  memcpy(&pe, header + 0x3c, 4);
  if (pe > sizeof header - 0x108 || memcmp(header + pe, "PE\0\0", 4)) return false;
  uint16_t machine, sections, optionalSize;
  memcpy(&machine, header + pe + 4, 2);
  memcpy(&sections, header + pe + 6, 2);
  memcpy(&optionalSize, header + pe + 20, 2);
  if (machine != 0x8664) return false;
  uint32_t table = pe + 24 + optionalSize;
  if (table + 40ULL * sections > sizeof header) return false;
  bool il2cpp = false;
  *image = (Image){.base = base};
  for (uint16_t i = 0; i < sections; i++) {
    const uint8_t *s = header + table + 40 * i;
    uint32_t virtualSize, rva;
    memcpy(&virtualSize, s + 8, 4);
    memcpy(&rva, s + 12, 4);
    if (!memcmp(s, ".text\0", 6)) image->textStart = base + rva, image->textSize = virtualSize;
    else if (!memcmp(s, ".data\0", 6)) image->dataStart = base + rva, image->dataSize = virtualSize;
    else if (!memcmp(s, "il2cpp", 6)) il2cpp = true;
  }
  return il2cpp && image->textSize && image->dataSize;
}

/* The preferred base first, then the start of every mapped region. */
static bool findImage(Image *image) {
  if (parseImage(PREFERRED_BASE, image)) return true;
  mach_vm_address_t address = 0;
  mach_vm_size_t size;
  vm_region_basic_info_data_64_t info;
  mach_msg_type_number_t count;
  mach_port_t object;
  for (;; address += size) {
    count = VM_REGION_BASIC_INFO_COUNT_64;
    if (mach_vm_region(mach_task_self(), &address, &size, VM_REGION_BASIC_INFO_64, (vm_region_info_t)&info,
                       &count, &object) != KERN_SUCCESS)
      return false;
    if ((info.protection & VM_PROT_READ) && parseImage(address, image)) return true;
  }
}

/* 66 0F 6E 0D ?? ?? ?? ?? 0F 57 C0 0F 5B C9: the operand of the movd, if it lies in .data. */
static uint64_t scan(const Image *image) {
  static const uint8_t head[] = {0x66, 0x0F, 0x6E, 0x0D}, tail[] = {0x0F, 0x57, 0xC0, 0x0F, 0x5B, 0xC9};
  enum { CHUNK = 1 << 20, OVERLAP = 16 };
  uint8_t *buffer = malloc(CHUNK + OVERLAP);
  uint64_t found = 0;
  for (uint64_t offset = 0; buffer && !found && offset < image->textSize; offset += CHUNK) {
    size_t size = image->textSize - offset < CHUNK + OVERLAP ? image->textSize - offset : CHUNK + OVERLAP;
    if (!readMemory(image->textStart + offset, buffer, size)) break;
    for (size_t i = 0; i + 14 <= size; i++) {
      if (memcmp(buffer + i, head, 4) || memcmp(buffer + i + 8, tail, 6)) continue;
      int32_t disp;
      memcpy(&disp, buffer + i + 4, 4);
      uint64_t variable = image->textStart + offset + i + 8 + (int64_t)disp;
      if (variable >= image->dataStart && variable + 4 <= image->dataStart + image->dataSize) {
        found = variable;
        break;
      }
    }
  }
  free(buffer);
  return found;
}

static void locate(void) {
  if (!image.base && !findImage(&image)) {
    image.base = 0;
    if (++findAttempts == FIND_SECONDS) giveUp("game image not found");
    return;
  }
  fpsVar = scan(&image);
  if (fpsVar) say("fps: variable at 0x%llx (image 0x%llx), forcing %d", fpsVar, image.base, target);
  else if (++scanAttempts == SCAN_TRIES) giveUp("frame-rate signature not found");
}

static void tick(void *ctx) {
  (void)ctx;
  if (!fpsVar) {
    locate();
    if (!fpsVar) return;
  }
  int32_t value;
  if (!readMemory(fpsVar, &value, sizeof value)) {
    giveUp("variable no longer readable");
    return;
  }
  if (value == target) {
    lastSeen = target; /* log the game's next write-back too */
    return;
  }
  if (value != lastSeen) say("fps: game set %d, writing %d", value, target);
  lastSeen = value;
  if (mach_vm_write(mach_task_self(), (mach_vm_address_t)fpsVar, (vm_offset_t)&target, sizeof target) != KERN_SUCCESS)
    giveUp("write failed");
}

void gamehost_fps_start(void) {
  const char *env = getenv("GENSHIN_LAUNCHER_FPS_TARGET");
  target = env ? atoi(env) : 0;
  if (target <= 0 || target > 1000) return;
  timer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, dispatch_get_global_queue(QOS_CLASS_UTILITY, 0));
  dispatch_source_set_timer(timer, dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC), NSEC_PER_SEC, NSEC_PER_SEC / 10);
  dispatch_source_set_event_handler_f(timer, tick);
  dispatch_resume(timer);
}
