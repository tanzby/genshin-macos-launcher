// Prints the frontmost app, current Space type per display, and on-screen
// windows owned by the given pids, as `key=value` lines for yaagl-diag.
// Usage: window-info <pid> [<pid> ...]
import AppKit
import CoreGraphics

typealias CopySpaces = @convention(c) (Int32) -> Unmanaged<CFArray>?
typealias MainConnection = @convention(c) () -> Int32

let pids = Set(CommandLine.arguments.dropFirst().compactMap { Int32($0) })

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

let windows =
  CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
  as? [[String: Any]] ?? []
for w in windows {
  guard let pid = w[kCGWindowOwnerPID as String] as? Int32, pids.contains(pid) else { continue }
  let b = w[kCGWindowBounds as String] as? [String: Any] ?? [:]
  print(
    "window id=\(w[kCGWindowNumber as String] ?? "-") pid=\(pid) layer=\(w[kCGWindowLayer as String] ?? "-") x=\(b["X"] ?? "-") y=\(b["Y"] ?? "-") w=\(b["Width"] ?? "-") h=\(b["Height"] ?? "-") owner=\(w[kCGWindowOwnerName as String] ?? "-")"
  )
}

