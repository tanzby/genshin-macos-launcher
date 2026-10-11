import Foundation
import Testing

@testable import Wine

@Suite struct WinePrefixCommandsTests {
  @Test func parsesDwordAndStringValues() {
    let dword = "HKEY_X\\Y\n    Width    REG_DWORD    0xa00\n"
    #expect(WinePrefixCommands.parseRegistryQuery(dword, name: "Width") == .dword(0xa00))
    let text = "HKEY_X\\Y\n    Name    REG_SZ    some text\n"
    #expect(WinePrefixCommands.parseRegistryQuery(text, name: "Name") == .string("some text"))
  }

  @Test func ignoresOtherNamesAndUnknownTypes() {
    let output = "    WidthExtra    REG_DWORD    0x1\n    Blob    REG_BINARY    00\n"
    #expect(WinePrefixCommands.parseRegistryQuery(output, name: "Width") == nil)
    #expect(WinePrefixCommands.parseRegistryQuery(output, name: "Blob") == nil)
  }

  @Test func argumentsFollowTheValueType() {
    #expect(WinePrefixCommands.registryArguments(.dword(7)) == ["/t", "REG_DWORD", "/d", "7"])
    #expect(WinePrefixCommands.registryArguments(.string("a")) == ["/t", "REG_SZ", "/d", "a"])
  }

  @Test func serverDirectoryIsNilForAMissingPrefix() {
    #expect(PrefixCleanup.serverDirectory(for: URL(filePath: "/nonexistent/prefix")) == nil)
    #expect(PrefixCleanup.serverDirectory(for: URL(filePath: "/tmp"))?.hasPrefix("/tmp/.wine-") == true)
  }
}
