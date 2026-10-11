import Foundation
import Platform

/// Closes a prefix: `wineserver -k`, then SIGKILL for what is left.
struct PrefixCleanup: Sendable {
  let layout: WineLayout
  let commands: WinePrefixCommands
  let processes: any ProcessTable

  /// `wineserver -k`, then SIGKILL for what is left: processes holding the prefix's server directory, and
  /// orphans whose Windows command line starts at `C:\` or `Z:\` with the prefix as working directory.
  func shutdown() async {
    _ = try? await commands.wineserver("-k")
    let serverDirectory = Self.serverDirectory(for: layout.prefixDirectory)
    let prefixPath = layout.prefixDirectory.resolvingSymlinksInPath().path
    let own = ProcessInfo.processInfo.processIdentifier
    for process in processes.processes(includeOpenPaths: true) where process.pid != own {
      // `/tmp` is a symlink to `/private/tmp`, and libproc reports the resolved path.
      let holdsServer =
        serverDirectory.map { directory in
          process.openPaths.contains { $0.hasPrefix(directory + "/") || $0.hasPrefix("/private" + directory + "/") }
        } ?? false
      let orphan =
        (process.arguments.first.map { $0.hasPrefix("C:\\") || $0.hasPrefix("Z:\\") } ?? false)
        && (process.workingDirectory.map { Self.isInside($0, directory: prefixPath) } ?? false)
      if holdsServer || orphan { processes.kill(process.pid) }
    }
  }

  static func serverDirectory(for prefix: URL) -> String? {
    var info = stat()
    guard stat(prefix.path, &info) == 0 else { return nil }
    let device = String(UInt64(bitPattern: Int64(info.st_dev)), radix: 16)
    let inode = String(info.st_ino, radix: 16)
    return "/tmp/.wine-\(getuid())/server-\(device)-\(inode)"
  }

  private static func isInside(_ path: String, directory: String) -> Bool {
    let resolved = URL(filePath: path).resolvingSymlinksInPath().path
    return resolved == directory || resolved.hasPrefix(directory + "/")
  }

}
