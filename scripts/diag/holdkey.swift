// Usage: holdkey <virtual keycode> <seconds>. Posts a HID key down, waits, then the key up, also on SIGTERM/SIGINT.
// The poster needs Accessibility access. Used by fps-measure to walk the character.
import CoreGraphics
import Foundation

func post(_ down: Bool) {
  let code = CGKeyCode(CommandLine.arguments[1])!
  CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: down)!.post(tap: .cghidEventTap)
}
let seconds = Double(CommandLine.arguments[2])!
for sig in [SIGTERM, SIGINT] {
  signal(sig) { _ in
    post(false)
    exit(1)
  }
}
post(true)
usleep(useconds_t(seconds * 1_000_000))
post(false)
