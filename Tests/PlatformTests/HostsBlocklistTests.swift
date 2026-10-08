import Foundation
import Testing

@testable import Platform

@Suite struct HostsBlocklistTests {
  static let domains = ["a.example.com", "b.example.com", "c.example.com"]
  static let system = "127.0.0.1\tlocalhost\n255.255.255.255\tbroadcasthost\n::1 localhost\n"

  private func makeBlocklist(_ temp: TempDir, hosts: String?, admin: ShellAdmin = ShellAdmin())
    throws -> (HostsBlocklist, ShellAdmin, URL)
  {
    let file = temp.path("hosts")
    if let hosts { try hosts.write(to: file, atomically: true, encoding: .utf8) }
    let blocklist = HostsBlocklist(
      domains: Self.domains, hostsFile: file, admin: admin, scratchDirectory: temp.url)
    return (blocklist, admin, file)
  }

  @Test func WIN_011_sectionHasMarkersAndOneZeroRoutePerDomain() {
    let section = HostsBlocklist.section(for: Self.domains)
    let lines = section.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
    #expect(lines.first == "# Added by Yaagl")
    #expect(lines.contains("# End of section"))
    let routes = lines.filter { $0.hasPrefix("0.0.0.0 ") }
    #expect(routes == Self.domains.map { "0.0.0.0 \($0)" })
    #expect(section.hasSuffix("\n"))
  }

  @Test func WIN_011_statusIsMissingWithoutSection() throws {
    let temp = try TempDir()
    defer { temp.cleanup() }
    let (blocklist, _, _) = try makeBlocklist(temp, hosts: Self.system)
    #expect(try blocklist.status() == .missing)
  }

  @Test func WIN_011_statusIsMissingWhenHostsFileDoesNotExist() throws {
    let temp = try TempDir()
    defer { temp.cleanup() }
    let (blocklist, _, _) = try makeBlocklist(temp, hosts: nil)
    #expect(try blocklist.status() == .missing)
  }

  @Test func WIN_011_statusIsCurrentWhenSectionMatches() throws {
    let temp = try TempDir()
    defer { temp.cleanup() }
    let hosts = Self.system + "\n" + HostsBlocklist.section(for: Self.domains)
    let (blocklist, _, _) = try makeBlocklist(temp, hosts: hosts)
    #expect(try blocklist.status() == .current)
  }

  @Test func WIN_011_statusIsOutdatedWhenADomainIsMissingOrChanged() throws {
    let temp = try TempDir()
    defer { temp.cleanup() }
    let stale = HostsBlocklist.section(for: Array(Self.domains.dropLast()))
    let (blocklist, _, _) = try makeBlocklist(temp, hosts: Self.system + stale)
    #expect(try blocklist.status() == .outdated)
  }

  @Test func WIN_011_statusIsOutdatedWhenSectionHasNoEndMarker() throws {
    let temp = try TempDir()
    defer { temp.cleanup() }
    let hosts = Self.system + "# Added by Yaagl\n0.0.0.0 a.example.com\n"
    let (blocklist, _, _) = try makeBlocklist(temp, hosts: hosts)
    #expect(try blocklist.status() == .outdated)
  }

  @Test func WIN_011_applyAppendsSectionAndKeepsEveryOtherLine() async throws {
    let temp = try TempDir()
    defer { temp.cleanup() }
    let original = Self.system + "10.0.0.5 100% weird\\n host\n"  // `%` and `\` must survive
    let (blocklist, admin, file) = try makeBlocklist(temp, hosts: original)

    try await blocklist.apply()

    let result = try String(contentsOf: file, encoding: .utf8)
    #expect(result.hasPrefix(original))
    #expect(result.contains(HostsBlocklist.section(for: Self.domains)))
    #expect(try blocklist.status() == .current)
    #expect(admin.commands.count == 1)
  }

  @Test func WIN_011_applyReplacesOutdatedSectionInPlace() async throws {
    let temp = try TempDir()
    defer { temp.cleanup() }
    let stale = "# Added by Yaagl\n# old\n0.0.0.0 old.example.com\n# End of section\n"
    let hosts = Self.system + stale + "192.168.0.2 nas\n"
    let (blocklist, _, file) = try makeBlocklist(temp, hosts: hosts)

    try await blocklist.apply()

    let result = try String(contentsOf: file, encoding: .utf8)
    #expect(!result.contains("old.example.com"))
    #expect(result.contains("192.168.0.2 nas"))
    #expect(result.components(separatedBy: "# Added by Yaagl").count == 2)
    #expect(try blocklist.status() == .current)
  }

  @Test func WIN_011_unterminatedSectionOnlyLosesItsOwnLines() async throws {
    // The TS version dropped everything after an unterminated start marker.
    let temp = try TempDir()
    defer { temp.cleanup() }
    let hosts = Self.system + "# Added by Yaagl\n0.0.0.0 a.example.com\n192.168.0.2 nas\n"
    let (blocklist, _, file) = try makeBlocklist(temp, hosts: hosts)

    try await blocklist.apply()

    let result = try String(contentsOf: file, encoding: .utf8)
    #expect(result.contains("192.168.0.2 nas"))
    #expect(try blocklist.status() == .current)
  }

  @Test func WIN_011_duplicateSectionsCollapseToOne() async throws {
    let temp = try TempDir()
    defer { temp.cleanup() }
    let section = HostsBlocklist.section(for: Self.domains)
    let (blocklist, _, file) = try makeBlocklist(temp, hosts: section + "1.2.3.4 mid\n" + section)

    try await blocklist.apply()

    let result = try String(contentsOf: file, encoding: .utf8)
    #expect(result.components(separatedBy: "# Added by Yaagl").count == 2)
    #expect(result.contains("1.2.3.4 mid"))
  }

  @Test func WIN_011_applyWhenCurrentDoesNotAskForAPassword() async throws {
    let temp = try TempDir()
    defer { temp.cleanup() }
    let hosts = Self.system + HostsBlocklist.section(for: Self.domains)
    let (blocklist, admin, _) = try makeBlocklist(temp, hosts: hosts)

    try await blocklist.apply()

    #expect(admin.commands.isEmpty)
  }

  @Test func WIN_011_cancelledPasswordPromptLeavesHostsUntouchedAndPropagates() async throws {
    let temp = try TempDir()
    defer { temp.cleanup() }
    let admin = ShellAdmin()
    admin.failure = AdminPrivilegeError.cancelled
    let (blocklist, _, file) = try makeBlocklist(temp, hosts: Self.system, admin: admin)

    await #expect(throws: AdminPrivilegeError.cancelled) { try await blocklist.apply() }

    #expect(try String(contentsOf: file, encoding: .utf8) == Self.system)
    #expect(try blocklist.status() == .missing)
  }

  @Test func WIN_011_commandQuotesPathsWithSpacesAndQuotes() async throws {
    let temp = try TempDir()
    defer { temp.cleanup() }
    let scratch = temp.path("it's a dir")
    try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
    let file = temp.path("my hosts")
    try Self.system.write(to: file, atomically: true, encoding: .utf8)
    let blocklist = HostsBlocklist(
      domains: Self.domains, hostsFile: file, admin: ShellAdmin(), scratchDirectory: scratch)

    try await blocklist.apply()

    #expect(try blocklist.status() == .current)
    #expect(try FileManager.default.contentsOfDirectory(atPath: scratch.path).isEmpty)
  }

  @Test func LCH_021_missingOrOutdatedBlocklistBlocksLaunch() {
    #expect(HostsBlocklist.Status.current.allowsLaunch)
    #expect(!HostsBlocklist.Status.missing.allowsLaunch)
    #expect(!HostsBlocklist.Status.outdated.allowsLaunch)
  }
}

@Suite struct AdminShellTests {
  @Test func APP_002_scriptEscapesBackslashesAndQuotes() {
    let script = AdminShell.appleScript(for: #"/bin/echo "a\b""#)
    #expect(script == #"do shell script "/bin/echo \"a\\b\"" with administrator privileges"#)
  }

  @Test func WIN_011_shellQuoteHandlesSingleQuotes() {
    #expect(AdminShell.shellQuote("it's") == #"'it'\''s'"#)
    #expect(AdminShell.shellQuote("a b") == "'a b'")
  }
}
