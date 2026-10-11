import Foundation
import Platform

/// Runs `reg` and `wineserver` against one prefix.
struct WinePrefixCommands: Sendable {
  let layout: WineLayout
  let runner: any ProcessRunning

  static func registryArguments(_ value: RegistryValue) -> [String] {
    switch value {
    case .dword(let number): ["/t", "REG_DWORD", "/d", String(number)]
    case .string(let text): ["/t", "REG_SZ", "/d", text]
    }
  }

  func query(key: String, name: String) async throws -> RegistryValue? {
    let result = try await reg(["query", key, "/v", name])
    guard result.exitCode == 0 else { return nil }
    return Self.parseRegistryQuery(result.output, name: name)
  }

  /// Parses `reg query` output: `    <name>    REG_DWORD    0xa00` or `    <name>    REG_SZ    text`.
  static func parseRegistryQuery(_ output: String, name: String) -> RegistryValue? {
    for line in output.components(separatedBy: .newlines) {
      let trimmed = line.trimmingCharacters(in: .whitespaces)
      guard trimmed.hasPrefix(name) else { continue }
      let rest = trimmed.dropFirst(name.count)
      guard rest.first?.isWhitespace == true else { continue }
      let parts = rest.split(maxSplits: 1, whereSeparator: \.isWhitespace)
      guard parts.count == 2 else { continue }
      let data = parts[1].trimmingCharacters(in: .whitespaces)
      switch parts[0] {
      case "REG_DWORD":
        let digits = data.lowercased().hasPrefix("0x") ? String(data.dropFirst(2)) : data
        return UInt32(digits, radix: 16).map(RegistryValue.dword)
      case "REG_SZ":
        return .string(data)
      default:
        return nil
      }
    }
    return nil
  }


  func set(_ key: String, _ name: String, _ value: RegistryValue) async throws -> ProcessResult {
    try await reg(["add", key, "/v", name] + Self.registryArguments(value) + ["/f"])
  }

  func delete(_ key: String, _ name: String) async throws -> ProcessResult {
    try await reg(["delete", key, "/v", name, "/f"])
  }

  private func reg(_ arguments: [String]) async throws -> ProcessResult {
    try await runner.run(
      layout.loader, arguments: ["reg"] + arguments, environment: layout.wineEnvironment, workingDirectory: layout.root)
  }

  func wineserver(_ flag: String) async throws -> ProcessResult {
    try await runner.run(
      layout.wineserver, arguments: [flag], environment: ["WINEPREFIX": layout.prefixDirectory.path],
      workingDirectory: layout.root)
  }
}
