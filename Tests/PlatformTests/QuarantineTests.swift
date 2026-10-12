import Darwin
import Foundation
import Testing
import TestSupport

@testable import Platform

@Suite struct QuarantineTests {
  private func setQuarantine(_ url: URL) throws {
    let value = "0081;00000000;Genshin Launcher;"
    let status = value.withCString { setxattr(url.path, "com.apple.quarantine", $0, strlen($0), 0, 0) }
    try #require(status == 0)
  }

  private func hasQuarantine(_ url: URL) -> Bool {
    getxattr(url.path, "com.apple.quarantine", nil, 0, 0, 0) >= 0
  }

  @Test func WIN_010_removesQuarantineRecursivelyWithoutPrivileges() throws {
    let temp = TempDir()
    try temp.makeFile("wine/bin/wine")
    try temp.makeFile("wine/lib/a.dylib")
    for name in ["wine", "wine/bin", "wine/bin/wine", "wine/lib/a.dylib"] {
      try setQuarantine(temp.path(name))
    }

    try Quarantine.remove(from: temp.path("wine"))

    for name in ["wine", "wine/bin", "wine/bin/wine", "wine/lib/a.dylib"] {
      #expect(!hasQuarantine(temp.path(name)), "\(name)")
    }
  }

  @Test func WIN_010_filesWithoutTheAttributeAreFine() throws {
    let temp = TempDir()
    try temp.makeFile("wine/bin/wine")

    try Quarantine.remove(from: temp.path("wine"))
  }

  @Test func WIN_010_doesNotFollowSymlinksOutOfTheTree() throws {
    let temp = TempDir()
    try temp.makeFile("wine/bin/wine")
    try temp.makeFile("outside/file")
    try setQuarantine(temp.path("outside/file"))
    try FileManager.default.createSymbolicLink(
      at: temp.path("wine/link"), withDestinationURL: temp.path("outside"))

    try Quarantine.remove(from: temp.path("wine"))

    #expect(hasQuarantine(temp.path("outside/file")))
  }

  @Test func WIN_010_missingRootIsAnError() throws {
    let temp = TempDir()
    #expect(throws: (any Error).self) { try Quarantine.remove(from: temp.path("nope")) }
  }
}
