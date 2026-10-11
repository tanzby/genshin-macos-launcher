// Compares what the game rendered (its drawable, saved by gamehost-dev) with
// what is on screen, as `key=value` text for yaagl-diag.
// Usage: screen-compare <drawable.png> <screen.png> <strip px>
//
// Both images are reduced to a per-row mean luma profile; a drawable smaller
// than the screen with the same aspect ratio (Retina off) is scaled to the
// screen's height. The screen should show the whole drawable at the same
// place: a black strip over the top <strip> rows (the screen's top safe-area
// inset) means something covers the game; a best match at a vertical offset
// means the picture is shifted or cropped; a different aspect ratio means the
// window is not the shape of the screen.
import AppKit

func rowLuma(_ path: String) -> (w: Int, h: Int, rows: [Double])? {
  guard let img = NSImage(contentsOfFile: path) else { return nil }
  var rect = CGRect(origin: .zero, size: img.size)
  guard let cg = img.cgImage(forProposedRect: &rect, context: nil, hints: nil) else { return nil }
  let w = cg.width, h = cg.height
  var buf = [UInt8](repeating: 0, count: w * h * 4)
  guard let ctx = CGContext(data: &buf, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
    space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
  else { return nil }
  ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
  var rows = [Double](repeating: 0, count: h)
  for y in 0..<h {
    var sum = 0.0, n = 0.0
    for x in stride(from: 0, to: w, by: 4) {
      let i = (y * w + x) * 4
      sum += 0.299 * Double(buf[i]) + 0.587 * Double(buf[i + 1]) + 0.114 * Double(buf[i + 2])
      n += 1
    }
    rows[y] = sum / n
  }
  return (w, h, rows)
}

func mean(_ a: ArraySlice<Double>) -> Double { a.isEmpty ? 0 : a.reduce(0, +) / Double(a.count) }

/// Mean absolute difference of screen rows `range` against drawable rows shifted by `offset`.
func diff(_ s: [Double], _ d: [Double], _ range: Range<Int>, offset: Int) -> Double {
  var sum = 0.0, n = 0.0
  for y in range where y - offset >= 0 && y - offset < d.count {
    sum += abs(s[y] - d[y - offset])
    n += 1
  }
  return n > 0 ? sum / n : .infinity
}

/// `rows` resampled (linearly) to `count` rows.
func resample(_ rows: [Double], to count: Int) -> [Double] {
  (0..<count).map { y in
    let p = (Double(y) + 0.5) * Double(rows.count) / Double(count) - 0.5
    let i = max(0, min(rows.count - 1, Int(p.rounded(.down)))), j = min(rows.count - 1, i + 1)
    let t = max(0, p - Double(i))
    return rows[i] * (1 - t) + rows[j] * t
  }
}

let args = CommandLine.arguments
guard args.count == 4, let drawable = rowLuma(args[1]), let s = rowLuma(args[2]), let strip = Double(args[3])
else {
  print("verdict=error reason=unreadable")
  exit(1)
}
guard abs(Double(drawable.w) / Double(drawable.h) - Double(s.w) / Double(s.h)) < 0.01 else {
  print("verdict=size-mismatch drawable=\(drawable.w)x\(drawable.h) screen=\(s.w)x\(s.h)")
  exit(0)
}
let game = drawable.h == s.h ? drawable.rows : resample(drawable.rows, to: s.h)
let top = 0..<min(max(Int(strip), 1), s.h)
let body = 100..<(s.h - 100)
var best = 0, bestDiff = Double.infinity
for off in -120...120 {
  let d = diff(s.rows, game, body, offset: off)
  if d < bestDiff { (best, bestDiff) = (off, d) }
}
let topScreen = mean(s.rows[top]), topDrawable = mean(game[top])
let topDiff = diff(s.rows, game, top, offset: 0), bodyDiff = diff(s.rows, game, body, offset: 0)
let verdict: String
if topScreen < 3 && topDrawable > 10 {
  verdict = "covered"
} else if abs(best) > 3 && bestDiff <= 20 {
  verdict = "shifted"
} else if topDiff > 20 || bodyDiff > 20 {
  verdict = "mismatch"
} else {
  verdict = "ok"
}
print(String(format: "verdict=%@ size=%dx%d drawable=%dx%d strip=%d top_luma_screen=%.0f top_luma_game=%.0f top_diff=%.1f body_diff=%.1f best_offset=%d",
  verdict, s.w, s.h, drawable.w, drawable.h, top.count, topScreen, topDrawable, topDiff, bodyDiff, best))
