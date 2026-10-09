import Foundation
import Testing

@testable import Wine

@Suite("WIN-009 wine.inf certificate injection") struct WineInfTests {
  static let sample = """
    [Version]
    Signature="$CHICAGO$"

    ; URL Associations
    HKCR,"http",,,"URL:http"
    HKCR,"https",,,"URL:https"

    ; Next section
    [Strings]
    """

  static var blockLines: [String] { WineInfCertificate.block.split(separator: "\n", omittingEmptySubsequences: false).map(String.init) }

  @Test("WIN-009 block starts with the DWCA marker and carries the known thumbprint")
  func blockShape() {
    #expect(WineInfCertificate.block.hasPrefix("; DWCA :xdd:"))
    #expect(WineInfCertificate.block.contains("F09065E2D57F005BBD975DDCF9EB63F570764F17"))
  }

  @Test("WIN-009 inserts blank line plus block at the first blank line after URL Associations")
  func insertsAfterSection() throws {
    let output = try WineInf.injectingCertificate(into: Self.sample)
    let lines = output.components(separatedBy: "\n")
    let start = try #require(lines.firstIndex(of: "; DWCA :xdd:"))
    #expect(lines.prefix(start - 1).elementsEqual(Self.sample.components(separatedBy: "\n").prefix(start - 1)))
    #expect(lines[start - 1] == "")
    #expect(lines[start - 2] == "HKCR,\"https\",,,\"URL:https\"")
    #expect(Array(lines[start..<(start + Self.blockLines.count)]) == Self.blockLines)
    let next = try #require(lines.firstIndex(of: "; Next section"))
    #expect(next > start + Self.blockLines.count - 1)
    #expect(lines.last == "[Strings]")
  }

  @Test("WIN-009 ignores blank lines before the URL Associations marker")
  func ignoresEarlierBlankLines() throws {
    let output = try WineInf.injectingCertificate(into: Self.sample)
    let lines = output.components(separatedBy: "\n")
    let marker = try #require(lines.firstIndex(of: "; URL Associations"))
    let block = try #require(lines.firstIndex(of: "; DWCA :xdd:"))
    #expect(block > marker)
  }

  @Test("WIN-009 matches the marker by trimmed text")
  func trimmedMarker() throws {
    let text = "[A]\n\n  ; URL Associations \t\nfoo\n\nbar\n"
    let output = try WineInf.injectingCertificate(into: text)
    #expect(output.contains("; DWCA :xdd:"))
    let lines = output.components(separatedBy: "\n")
    #expect(try #require(lines.firstIndex(of: "; DWCA :xdd:")) > (try #require(lines.firstIndex(of: "foo"))))
  }

  @Test("WIN-009 accepts CRLF input and emits LF only")
  func crlfInput() throws {
    let crlf = Self.sample.replacingOccurrences(of: "\n", with: "\r\n")
    let output = try WineInf.injectingCertificate(into: crlf)
    #expect(!output.contains("\r"))
    #expect(output == (try WineInf.injectingCertificate(into: Self.sample)))
  }

  @Test("WIN-009 throws certificateSectionNotFound without the URL Associations marker")
  func missingMarker() {
    #expect(throws: WineInstallError.certificateSectionNotFound) {
      try WineInf.injectingCertificate(into: "[Version]\n\nfoo\n")
    }
  }

  @Test("WIN-009 throws certificateSectionNotFound when no blank line follows the marker")
  func missingBlankLine() {
    #expect(throws: WineInstallError.certificateSectionNotFound) {
      try WineInf.injectingCertificate(into: "[A]\n\n; URL Associations\nfoo\nbar")
    }
  }

  @Test("WIN-009 injection is idempotent")
  func idempotent() throws {
    let once = try WineInf.injectingCertificate(into: Self.sample)
    let twice = try WineInf.injectingCertificate(into: once)
    #expect(once == twice)
    #expect(twice.components(separatedBy: "F09065E2D57F005BBD975DDCF9EB63F570764F17").count == 2)
  }
}
