import AppKit
import Foundation
import Wine

/// What the standard About panel and the Advanced page list (CFG-034). Names and licenses are not translated.
enum Credits {
  struct Component {
    var name: String
    var license: String
  }

  static let components: [Component] = [
    Component(name: "Wine \(WineRuntime.pinnedVersion)", license: "LGPL-2.1-or-later"),
    Component(name: "DXMT \(DXMTRelease.pinned.version)", license: "see upstream"),
    Component(name: "Proton steam_helper, lsteamclient (Valve)", license: "BSD-3-Clause"),
    Component(name: "Sparkle", license: "MIT"),
    Component(name: "swift-protobuf", license: "Apache-2.0"),
    Component(name: "zstd", license: "BSD-3-Clause"),
    Component(name: "Yet Another Anime Game Launcher", license: "MIT"),
  ]

  static var attributed: NSAttributedString {
    let paragraph = NSMutableParagraphStyle()
    paragraph.alignment = .center
    let text = components.map { "\($0.name) — \($0.license)" }.joined(separator: "\n")
    return NSAttributedString(
      string: text,
      attributes: [
        .font: NSFont.systemFont(ofSize: 11),
        .foregroundColor: NSColor.secondaryLabelColor,
        .paragraphStyle: paragraph,
      ])
  }
}
