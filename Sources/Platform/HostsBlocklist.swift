import Foundation

/// The `# Added by Genshin Launcher` … `# End of section` block of `/etc/hosts` that sends telemetry domains
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

  static let beginMarker = "# Added by Genshin Launcher"
  static let endMarker = "# End of section"
  static let warning = "# Warning: managed by Genshin Launcher. Edits inside this section are overwritten."
  package static let systemHostsFile = URL(filePath: "/etc/hosts")

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
    Self.status(of: try currentContents(), domains: domains)
  }

  static func status(of contents: String, domains: [String]) -> Status {
    let lines = Self.lines(of: contents)
    let sections = Self.sections(in: lines)
    guard let first = sections.first else { return .missing }
    let expected = Self.lines(of: Self.section(for: domains))
    let actual = lines[first.range].map(Self.trimmed)
    return sections.count == 1 && first.terminated && actual == expected ? .current : .outdated
  }

  /// Rewrites the section (appending it if absent) through an elevated, guarded `cp` of a temp
  /// file, so the file's content never passes through a shell or a format string. The copy only
  /// happens if `/etc/hosts` still equals the snapshot the new content was built from; if somebody
  /// else edited it while the password dialog was open, the whole step is redone on fresh content.
  public func apply() async throws {
    for attempt in 1...Self.maxAttempts {
      let snapshot = try currentContents()
      guard Self.status(of: snapshot, domains: domains) != .current else { return }
      let updated = Self.merged(section: Self.section(for: domains), into: snapshot)
      let id = UUID().uuidString
      let stagedNew = scratchDirectory.appending(path: "genshin-launcher-hosts-\(id)")
      let stagedOld = scratchDirectory.appending(path: "genshin-launcher-hosts-\(id).orig")
      try updated.write(to: stagedNew, atomically: true, encoding: .utf8)
      try snapshot.write(to: stagedOld, atomically: true, encoding: .utf8)
      defer {
        try? FileManager.default.removeItem(at: stagedNew)
        try? FileManager.default.removeItem(at: stagedOld)
      }

      let hosts = AdminShell.shellQuote(hostsFile.path)
      let command =
        "/usr/bin/cmp -s \(AdminShell.shellQuote(stagedOld.path)) \(hosts) && "
        + "/bin/cp \(AdminShell.shellQuote(stagedNew.path)) \(hosts)"
      do {
        try await admin.run(shellCommand: command)
      } catch AdminPrivilegeError.failed(let message) {
        // Retry only when the guard tripped, i.e. the file really changed under us.
        if try currentContents() != snapshot, attempt < Self.maxAttempts { continue }
        throw AdminPrivilegeError.failed(message)
      }
      guard try status() == .current else {
        throw AdminPrivilegeError.failed("hosts file does not contain the blocklist after writing")
      }
      return
    }
  }

  private static let maxAttempts = 3

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
    // components(separatedBy:) splits on the literal "\n"; Character splitting treats "\r\n" as one.
    var lines = text.components(separatedBy: "\n")
    if lines.last == "" { lines.removeLast() }
    return lines
  }

  /// Sections run from a begin marker to the next end marker. Without an end marker the section is
  /// only the contiguous lines Genshin Launcher itself writes, so unrelated lines after it survive.
  static func sections(in lines: [String]) -> [FoundSection] {
    var found: [FoundSection] = []
    var index = 0
    while index < lines.count {
      guard trimmed(lines[index]) == beginMarker else {
        index += 1
        continue
      }
      var end = index + 1
      var terminated = false
      if let close = lines[end...].firstIndex(where: { trimmed($0) == endMarker }),
        lines[end..<close].allSatisfy(isOwnLine)
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

  private static func trimmed(_ line: String) -> String {
    line.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  /// Inside a terminated section only comments and 0.0.0.0 routes can be ours; anything else means
  /// the end marker belongs to somebody else's block.
  private static func isOwnLine(_ line: String) -> Bool {
    let line = trimmed(line)
    return (line.hasPrefix("#") && line != beginMarker) || line.hasPrefix("0.0.0.0 ")
  }

  private static func isManagedLine(_ line: String) -> Bool {
    let line = trimmed(line)
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
