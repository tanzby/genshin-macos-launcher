import Foundation
import Wine

extension DXMTBundle {
  /// The DXMT inside this app (`Contents/Resources/dxmt`, built by `scripts/build-dxmt`); `nil` in a build that
  /// did not run it. `Wine` itself never reads `Bundle.main`.
  static let inApp: DXMTBundle? = {
    guard let resources = Bundle.main.resourceURL else { return nil }
    return load(from: resources.appending(path: "dxmt", directoryHint: .isDirectory))
  }()
}
