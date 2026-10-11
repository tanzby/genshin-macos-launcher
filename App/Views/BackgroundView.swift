import Launcher
import SwiftUI

/// The window background: the official artwork (or a built-in fallback) under a theme overlay. No video (#30).
struct BackgroundView: View {
  let source: BackgroundImage

  var body: some View {
    ZStack {
      fallback
      if case .remote(let url) = source {
        AsyncImage(url: url) { phase in
          if let image = phase.image {
            image.resizable().scaledToFill().transition(.opacity)
          }
        }
      }
      // Theme overlay: keeps the capsule legible whatever the artwork is.
      LinearGradient(
        colors: [.black.opacity(0), .black.opacity(0.35)], startPoint: .center, endPoint: .bottom)
    }
    .animation(.smooth, value: source)
    .accessibilityHidden(true)
  }

  private var fallback: some View {
    LinearGradient(
      colors: [Color(red: 0.10, green: 0.16, blue: 0.30), Color(red: 0.36, green: 0.24, blue: 0.40)],
      startPoint: .topLeading, endPoint: .bottomTrailing)
  }
}
