#ifndef YAAGL_HPATCH_H
#define YAAGL_HPATCH_H

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/// Result of `yaagl_hpatch_apply`.
typedef enum {
  YAAGL_HPATCH_OK = 0,
  YAAGL_HPATCH_CANCELLED = 1,
  /// The diff slice is not an HDiffPatch diff (`HDIFF13&...` or a single-stream diff).
  YAAGL_HPATCH_BAD_DIFF = 2,
  /// The diff is compressed; only uncompressed diffs are supported (the CN ldiff files are).
  YAAGL_HPATCH_UNSUPPORTED_COMPRESSION = 3,
  /// The diff's recorded old or new size differs from the file or the size the caller expects.
  YAAGL_HPATCH_SIZE_MISMATCH = 4,
  YAAGL_HPATCH_PATCH_FAILED = 5,
  YAAGL_HPATCH_IO_ERROR = 6,
  YAAGL_HPATCH_OUT_OF_MEMORY = 7,
} yaagl_hpatch_result;

/// Applies the HDiffPatch diff stored in `diff_fd` at `[diff_offset, diff_offset + diff_length)` to the
/// file `old_fd` and writes `expected_new_size` bytes to `out_fd` (a ldiff file concatenates many diffs,
/// so the slice is read in place). The descriptors stay open and owned by the caller.
/// `is_cancelled` (may be NULL) is polled between I/O steps; returning non-zero aborts the patch.
yaagl_hpatch_result yaagl_hpatch_apply(
    int old_fd, int diff_fd, uint64_t diff_offset, uint64_t diff_length, int out_fd,
    uint64_t expected_new_size, int (*is_cancelled)(void *context), void *context);

#ifdef __cplusplus
}
#endif

#endif
