import Launcher
import SwiftUI

struct MainView: View {
  @Environment(LauncherModel.self) private var launcher

  var body: some View {
    Text(String(describing: launcher.primaryAction))
      .frame(minWidth: 480, minHeight: 320)
      .task { await launcher.refresh() }
  }
}
