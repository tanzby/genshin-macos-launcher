// Thin file-descriptor front end over the vendored HDiffPatch patcher (hpatch/, v4.5.2, MIT).
#include "yaagl_hpatch.h"

#include <errno.h>
#include <stdlib.h>
#include <unistd.h>

#include "hpatch/patch.h"

// Memory the patcher may ask for on top of its I/O caches. A hostile diff cannot make us allocate more.
#define kMaxStepMem ((uint64_t)512 << 20)
#define kIOCache ((size_t)16 << 20)

typedef struct {
  int fd;
  uint64_t base;
  int (*is_cancelled)(void *);
  void *context;
  int cancelled;
  int io_failed;
} stream_ctx;

static hpatch_BOOL read_at(const hpatch_TStreamInput *stream, hpatch_StreamPos_t pos,
                           unsigned char *out, unsigned char *out_end) {
  stream_ctx *c = (stream_ctx *)stream->streamImport;
  if (c->is_cancelled && c->is_cancelled(c->context)) {
    c->cancelled = 1;
    return hpatch_FALSE;
  }
  while (out < out_end) {
    ssize_t n = pread(c->fd, out, (size_t)(out_end - out), (off_t)(c->base + pos));
    if (n < 0 && errno == EINTR) continue;
    if (n <= 0) {
      c->io_failed = 1;
      return hpatch_FALSE;
    }
    out += n;
    pos += (hpatch_StreamPos_t)n;
  }
  return hpatch_TRUE;
}

static hpatch_BOOL write_at(const hpatch_TStreamOutput *stream, hpatch_StreamPos_t pos,
                            const unsigned char *data, const unsigned char *data_end) {
  stream_ctx *c = (stream_ctx *)stream->streamImport;
  if (c->is_cancelled && c->is_cancelled(c->context)) {
    c->cancelled = 1;
    return hpatch_FALSE;
  }
  while (data < data_end) {
    ssize_t n = pwrite(c->fd, data, (size_t)(data_end - data), (off_t)(c->base + pos));
    if (n < 0 && errno == EINTR) continue;
    if (n <= 0) {
      c->io_failed = 1;
      return hpatch_FALSE;
    }
    data += n;
    pos += (hpatch_StreamPos_t)n;
  }
  return hpatch_TRUE;
}

static int file_size(int fd, uint64_t *size) {
  off_t end = lseek(fd, 0, SEEK_END);
  if (end < 0) return -1;
  *size = (uint64_t)end;
  return 0;
}

yaagl_hpatch_result yaagl_hpatch_apply(
    int old_fd, int diff_fd, uint64_t diff_offset, uint64_t diff_length, int out_fd,
    uint64_t expected_new_size, int (*is_cancelled)(void *context), void *context) {
  uint64_t old_size = 0;
  if (file_size(old_fd, &old_size) != 0) return YAAGL_HPATCH_IO_ERROR;

  stream_ctx old_ctx = {old_fd, 0, is_cancelled, context, 0, 0};
  stream_ctx diff_ctx = {diff_fd, diff_offset, is_cancelled, context, 0, 0};
  stream_ctx out_ctx = {out_fd, 0, is_cancelled, context, 0, 0};

  hpatch_TStreamInput old_stream = {&old_ctx, old_size, read_at, NULL};
  hpatch_TStreamInput diff_stream = {&diff_ctx, diff_length, read_at, NULL};
  hpatch_TStreamOutput out_stream = {&out_ctx, expected_new_size, NULL, write_at};

  hpatch_compressedDiffInfo plain;
  hpatch_singleCompressedDiffInfo single;
  int is_single = 0;
  if (getCompressedDiffInfo(&plain, &diff_stream)) {
    // "HDIFF13&" plus an empty compressor name: what the CN ldiff files are.
    if (plain.compressType[0] != '\0' || plain.compressedCount != 0) {
      return YAAGL_HPATCH_UNSUPPORTED_COMPRESSION;
    }
    if (plain.oldDataSize != old_size || plain.newDataSize != expected_new_size) {
      return YAAGL_HPATCH_SIZE_MISMATCH;
    }
  } else if (!diff_ctx.cancelled && !diff_ctx.io_failed &&
             getSingleCompressedDiffInfo(&single, &diff_stream, 0)) {
    is_single = 1;
    if (single.compressType[0] != '\0') return YAAGL_HPATCH_UNSUPPORTED_COMPRESSION;
    if (single.oldDataSize != old_size || single.newDataSize != expected_new_size) {
      return YAAGL_HPATCH_SIZE_MISMATCH;
    }
    if (single.stepMemSize > kMaxStepMem) return YAAGL_HPATCH_BAD_DIFF;
  } else {
    return diff_ctx.cancelled ? YAAGL_HPATCH_CANCELLED
           : diff_ctx.io_failed ? YAAGL_HPATCH_IO_ERROR
                                : YAAGL_HPATCH_BAD_DIFF;
  }

  size_t cache_size = (is_single ? (size_t)single.stepMemSize : 0) + kIOCache;
  unsigned char *cache = (unsigned char *)malloc(cache_size);
  if (!cache) return YAAGL_HPATCH_OUT_OF_MEMORY;

  hpatch_BOOL ok =
      is_single
          ? patch_single_compressed_diff(&out_stream, &old_stream, &diff_stream, single.diffDataPos,
                                         single.uncompressedSize, single.compressedSize, NULL,
                                         single.coverCount, (hpatch_size_t)single.stepMemSize, cache,
                                         cache + cache_size, NULL)
          : patch_decompress_with_cache(&out_stream, &old_stream, &diff_stream, NULL, cache,
                                        cache + cache_size);
  free(cache);
  if (ok) return YAAGL_HPATCH_OK;
  if (old_ctx.cancelled || diff_ctx.cancelled || out_ctx.cancelled) return YAAGL_HPATCH_CANCELLED;
  if (old_ctx.io_failed || diff_ctx.io_failed || out_ctx.io_failed) return YAAGL_HPATCH_IO_ERROR;
  return YAAGL_HPATCH_PATCH_FAILED;
}
