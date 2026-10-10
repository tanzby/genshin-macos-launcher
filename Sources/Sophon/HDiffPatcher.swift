import CHDiffPatch
import Foundation

/// UPG-009: applies one HDiffPatch diff, cut out of an ldiff file, to an old file.
enum HDiffPatcher {
  /// Writes the patched file to `output`. The slice `[offset, offset + length)` of `ldiff` is read in
  /// place. Throws `CancellationError` when `cancelled` is set and `SophonError.patchFailed` for
  /// anything else; the caller checks the result against the manifest.
  static func apply(
    old: URL, ldiff: URL, offset: Int64, length: Int64, to output: URL, expectedSize: Int64,
    name: String, cancelled: CancelFlag
  ) throws {
    guard offset >= 0, length > 0, expectedSize >= 0 else { throw SophonError.patchFailed(path: name) }
    let oldFD = open(old.path, O_RDONLY)
    guard oldFD >= 0 else { throw SophonError.patchFailed(path: name) }
    defer { close(oldFD) }
    let diffFD = open(ldiff.path, O_RDONLY)
    guard diffFD >= 0 else { throw SophonError.patchFailed(path: name) }
    defer { close(diffFD) }
    let outFD = open(output.path, O_WRONLY | O_CREAT | O_TRUNC, 0o644)
    guard outFD >= 0 else { throw SophonError.patchFailed(path: name) }
    defer { close(outFD) }

    let result = withExtendedLifetime(cancelled) {
      yaagl_hpatch_apply(
        oldFD, diffFD, UInt64(offset), UInt64(length), outFD, UInt64(expectedSize),
        { context in Unmanaged<CancelFlag>.fromOpaque(context!).takeUnretainedValue().isSet ? 1 : 0 },
        Unmanaged.passUnretained(cancelled).toOpaque())
    }
    switch result {
    case YAAGL_HPATCH_OK: return
    case YAAGL_HPATCH_CANCELLED: throw CancellationError()
    default: throw SophonError.patchFailed(path: name)
    }
  }
}
