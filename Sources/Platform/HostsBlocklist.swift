import Foundation

/// The `# Added by Yaagl` … `# End of section` block of `/etc/hosts` that sends telemetry domains
/// to 0.0.0.0. The domain list is game-specific and injected (GenshinCN owns it). Reading needs no
/// privileges; `apply()` asks for the administrator password once, and only when a change is needed.
public struct HostsBlocklist: Sendable {
  public enum Status: Sendable, Equatable {
    case current
    case missing
    /// A section exists but differs from the expected one (domains changed, or no end marker).
    case outdated

    /// The game must not start unless the blocklist is in place.
    public var allowsLaunch: Bool { self == .current }
  }

  static let beginMarker = "# Added by Yaagl"
  static let endMarker = "# End of section"
  static let warning = "# Warning: managed by Yaagl. Edits inside this section are overwritten."
  public static let systemHostsFile = URL(filePath: "/etc/hosts")

  public let domains: [String]
  let hostsFile: URL
  let admin: any AdminPrivilege
  let scratchDirectory: URL

  /// Production: the real `/etc/hosts`, `NSAppleScript` elevation.
  public init(domains: [String]) {
    self.init(domains: domains, hostsFile: Self.systemHostsFile, admin: AdminShell())
  }

  init(
    domains: [String],
    hostsFile: URL,
    admin: any AdminPrivilege,
    scratchDirectory: URL = FileManager.default.temporaryDirectory
  ) {
    self.domains = domains
    self.hostsFile = hostsFile
    self.admin = admin
    self.scratchDirectory = scratchDirectory
  }

  static func section(for domains: [String]) -> String {
    ([beginMarker, warning] + domains.map { "0.0.0.0 \($0)" } + [endMarker])
      .joined(separator: "\n") + "\n"
  }

  public func status() throws -> Status {
    let lines = Self.lines(of: try currentContents())
    let sections = Self.sections(in: lines)
    guard let first = sections.first else { return .missing }
    let expected = Self.section(for: domains).split(separator: "\n").map(String.init)
    let actual = lines[first.range].map { $0.trimmingCharacters(in: .whitespaces) }
    return sections.count == 1 && first.terminated && actual == expected ? .current : .outdated
  }

  /// Rewrites the section (appending it if absent) through an elevated `cp` of a temp file, so the
  /// file's content never passes through a shell or a format string.
  public func apply() async throws {
    guard try status() != .current else { return }
    let updated = Self.merged(section: Self.section(for: domains), into: try currentContents())
    let staged = scratchDirectory.appending(path: "yaagl-hosts-\(UUID().uuidString)")
    try updated.write(to: staged, atomically: true, encoding: .utf8)
    defer { try? FileManager.default.removeItem(at: staged) }

    try await admin.run(
      shellCommand: "/bin/cp \(AdminShell.shellQuote(staged.path)) \(AdminShell.shellQuote(hostsFile.path))")
    guard try status() == .current else {
      throw AdminPrivilegeError.failed("hosts file does not contain the blocklist after writing")
    }
  }

  private func currentContents() throws -> String {
    guard FileManager.default.fileExists(atPath: hostsFile.path) else { return "" }
    return try String(contentsOf: hostsFile, encoding: .utf8)
  }

  // MARK: Parsing

  struct FoundSection {
    var range: Range<Int>
    var terminated: Bool
  }

  static func lines(of text: String) -> [String] {
    var lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
    if lines.last == "" { lines.removeLast() }
    return lines
  }

  /// Sections run from a begin marker to the next end marker. Without an end marker the section is
  /// only the contiguous lines Yaagl itself writes, so unrelated lines after it survive.
  static func sections(in lines: [String]) -> [FoundSection] {
    var found: [FoundSection] = []
    var index = 0
    while index < lines.count {
      guard lines[index].trimmingCharacters(in: .whitespaces) == beginMarker else {
        index += 1
        continue
      }
      var end = index + 1
      var terminated = false
      if let close = lines[end...].firstIndex(where: { $0.trimmingCharacters(in: .whitespaces) == endMarker }),
        lines[end..<close].allSatisfy({ !isBeginMarker($0) })
      {
        end = close + 1
        terminated = true
      } else {
        while end < lines.count, isManagedLine(lines[end]) { end += 1 }
      }
      found.append(FoundSection(range: index..<end, terminated: terminated))
      index = end
    }
    return found
  }

  private static func isBeginMarker(_ line: String) -> Bool {
    line.trimmingCharacters(in: .whitespaces) == beginMarker
  }

  private static func isManagedLine(_ line: String) -> Bool {
    let line = line.trimmingCharacters(in: .whitespaces)
    return line == warning || line.hasPrefix("0.0.0.0 ")
  }

  /// Replaces the first section in place, drops further ones, or appends when there is none.
  static func merged(section: String, into text: String) -> String {
    let existing = lines(of: text)
    let found = sections(in: existing)
    guard let first = found.first else {
      var result = text
      if !result.isEmpty && !result.hasSuffix("\n") { result += "\n" }
      return result + (result.isEmpty ? "" : "\n") + section
    }
    var output: [String] = []
    var index = 0
    for current in found {
      output += existing[index..<current.range.lowerBound]
      if current.range == first.range { output += lines(of: section) }
      index = current.range.upperBound
    }
    output += existing[index...]
    return output.joined(separator: "\n") + "\n"
  }
}
