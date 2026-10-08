import Foundation

public enum AdminPrivilegeError: Error, Equatable {
  /// The user dismissed the password dialog.
  case cancelled
  case failed(String)
}

/// In-process `NSAppleScript` with `with administrator privileges`. Internal on purpose: its only
/// caller is `HostsBlocklist`, so the module never offers "run anything as root".
struct AdminShell: AdminPrivilege {
  private static let userCancelledCode = -128

  func run(shellCommand: String) async throws {
    let source = Self.appleScript(for: shellCommand)
    // NSAppleScript is not thread-safe and shows UI; run it on the main actor.
    let failure: (code: Int, message: String)? = await MainActor.run {
      var error: NSDictionary?
      NSAppleScript(source: source)?.executeAndReturnError(&error)
      guard let error else { return nil }
      let code = (error[NSAppleScript.errorNumber] as? Int) ?? 0
      let message = (error[NSAppleScript.errorMessage] as? String) ?? "unknown AppleScript error"
      return (code, message)
    }
    guard let failure else { return }
    if failure.code == Self.userCancelledCode { throw AdminPrivilegeError.cancelled }
    throw AdminPrivilegeError.failed(failure.message)
  }

  static func appleScript(for shellCommand: String) -> String {
    let escaped = shellCommand
      .replacingOccurrences(of: "\\", with: "\\\\")
      .replacingOccurrences(of: "\"", with: "\\\"")
    return "do shell script \"\(escaped)\" with administrator privileges"
  }

  /// POSIX single-quote quoting for one shell word.
  static func shellQuote(_ word: String) -> String {
    "'" + word.replacingOccurrences(of: "'", with: "'\\''") + "'"
  }
}
