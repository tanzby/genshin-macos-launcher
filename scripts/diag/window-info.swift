// Prints the frontmost app, current Space type per display, and on-screen
// windows owned by the given pids, as `key=value` lines for genshin-launcher-diag.
// Usage: window-info [--all] <pid> [<pid> ...]
//        window-info --activate <pid> --timeout <seconds 0...30>
import AppKit
import CoreGraphics
import Darwin

typealias CopySpaces = @convention(c) (Int32) -> Unmanaged<CFArray>?
typealias MainConnection = @convention(c) () -> Int32

let arguments = Array(CommandLine.arguments.dropFirst())
let allSpaces = arguments.first == "--all"

func windows(onScreenOnly: Bool) -> [[String: Any]] {
  let option: CGWindowListOption = onScreenOnly ? .optionOnScreenOnly : .optionAll
  return CGWindowListCopyWindowInfo([option, .excludeDesktopElements], kCGNullWindowID)
    as? [[String: Any]] ?? []
}

func isOnScreen(_ window: [String: Any]) -> Bool {
  (window[kCGWindowIsOnscreen as String] as? NSNumber)?.boolValue ?? false
}

func printWindow(_ window: [String: Any], pid: Int32, location: String? = nil) {
  let bounds = window[kCGWindowBounds as String] as? [String: Any] ?? [:]
  let suffix = location.map { " onscreen=\(isOnScreen(window) ? 1 : 0) space=\($0)" } ?? ""
  print(
    "window id=\(window[kCGWindowNumber as String] ?? "-") pid=\(pid) layer=\(window[kCGWindowLayer as String] ?? "-") x=\(bounds["X"] ?? "-") y=\(bounds["Y"] ?? "-") w=\(bounds["Width"] ?? "-") h=\(bounds["Height"] ?? "-") owner=\(window[kCGWindowOwnerName as String] ?? "-")\(suffix)"
  )
}

func printWindows(for pids: Set<Int32>, allSpaces: Bool) -> Int {
  let all = windows(onScreenOnly: !allSpaces)
  let matches = all.filter {
    guard let pid = $0[kCGWindowOwnerPID as String] as? Int32 else { return false }
    return pids.contains(pid)
  }
  if allSpaces {
    let onScreenCount = matches.filter(isOnScreen).count
    print("windows count=\(matches.count) onscreen=\(onScreenCount) offscreen=\(matches.count - onScreenCount)")
  }
  for window in matches {
    guard let pid = window[kCGWindowOwnerPID as String] as? Int32 else { continue }
    let location = allSpaces ? (isOnScreen(window) ? "current" : "not-current-or-hidden") : nil
    printWindow(window, pid: pid, location: location)
  }
  return matches.count
}

func activate(pid: Int32, timeout: TimeInterval) -> Int32 {
  guard let app = NSRunningApplication(processIdentifier: pid) else {
    fputs("activation error=process-not-found pid=\(pid)\n", stderr)
    return 2
  }

  let requested = app.activate(options: [.activateAllWindows])
  print("activation pid=\(pid) requestAllowed=\(requested ? 1 : 0) isActive=\(app.isActive ? 1 : 0)")
  let deadline = Date().addingTimeInterval(timeout)
  var onscreenCount = 0
  var isActive = app.isActive
  repeat {
    onscreenCount = windows(onScreenOnly: true).filter {
      ($0[kCGWindowOwnerPID as String] as? Int32) == pid
    }.count
    isActive = app.isActive
    if onscreenCount > 0 && isActive {
      print("activation result=active-and-onscreen pid=\(pid) isActive=1 windows=\(onscreenCount)")
      _ = printWindows(for: [pid], allSpaces: true)
      return 0
    }
    if Date() >= deadline { break }
    RunLoop.current.run(until: Date().addingTimeInterval(min(0.25, max(0, deadline.timeIntervalSinceNow))))
  } while Date() < deadline

  print("activation result=timeout pid=\(pid) isActive=\(isActive ? 1 : 0) onscreen=\(onscreenCount)")
  _ = printWindows(for: [pid], allSpaces: true)
  return 1
}

if arguments.first == "--activate" {
  guard arguments.count == 4, arguments[2] == "--timeout",
    let pid = Int32(arguments[1]), pid > 0,
    let timeout = Double(arguments[3]), timeout >= 0, timeout <= 30
  else {
    fputs("usage: window-info --activate <pid> --timeout <seconds 0...30>\n", stderr)
    exit(2)
  }
  exit(activate(pid: pid, timeout: timeout))
}

let pids = Set(arguments.dropFirst(allSpaces ? 1 : 0).compactMap { Int32($0) })

if let app = NSWorkspace.shared.frontmostApplication {
  print(
    "front pid=\(app.processIdentifier) bundle=\(app.bundleIdentifier ?? "-") name=\(app.localizedName ?? "-")"
  )
}

// SkyLight is private; space type 0 = desktop, 4 = native full-screen Space.
if let sl = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_LAZY),
  let mainSym = dlsym(sl, "SLSMainConnectionID"),
  let spacesSym = dlsym(sl, "SLSCopyManagedDisplaySpaces")
{
  let conn = unsafeBitCast(mainSym, to: MainConnection.self)()
  let displays = unsafeBitCast(spacesSym, to: CopySpaces.self)(conn)?.takeRetainedValue()
    as? [[String: Any]] ?? []
  for display in displays {
    let current = display["Current Space"] as? [String: Any] ?? [:]
    print(
      "space display=\(display["Display Identifier"] ?? "-") type=\(current["type"] ?? "-") id=\(current["ManagedSpaceID"] ?? "-")"
    )
  }
}

for screen in NSScreen.screens {
  let f = screen.frame
  print("screen w=\(Int(f.width)) h=\(Int(f.height))")
}

_ = printWindows(for: pids, allSpaces: allSpaces)

