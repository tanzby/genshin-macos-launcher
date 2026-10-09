import Foundation
import Testing

@testable import Platform

@Suite struct ProcessTableTests {
  @Test func WIN_018_systemTableSeesOwnProcessWithArgumentsAndCwd() {
    let own = getpid()
    let records = SystemProcessTable().processes(includeOpenPaths: true)
    let me = records.first { $0.pid == own }
    #expect(me != nil)
    #expect(me?.arguments.isEmpty == false)
    #expect(me?.workingDirectory == FileManager.default.currentDirectoryPath)
  }

  @Test func WIN_018_systemTableListsOpenFiles() throws {
    let url = FileManager.default.temporaryDirectory.appending(path: "yaagl-open-\(UUID().uuidString)")
    try Data("x".utf8).write(to: url)
    defer { try? FileManager.default.removeItem(at: url) }
    let handle = try FileHandle(forReadingFrom: url)
    defer { try? handle.close() }
    let me = SystemProcessTable().processes(includeOpenPaths: true).first { $0.pid == getpid() }
    #expect(me?.openPaths.contains { $0.hasSuffix(url.lastPathComponent) } == true)
  }
}
