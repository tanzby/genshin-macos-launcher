import Foundation
import Wine

extension GPTK4Bundle {
  /// The official GPTK payload staged by `scripts/prepare-gptk4`; nil in ordinary builds without it.
  static let inApp: GPTK4Bundle? = {
    guard let resources = Bundle.main.resourceURL else { return nil }
    return load(from: resources.appending(path: "gptk4/lib", directoryHint: .isDirectory))
  }()
}
