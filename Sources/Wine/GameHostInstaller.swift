import CoreServices
import Foundation
import Platform
import os

/// Production `LaunchServicesRegistering` on `LSRegisterURL`.
package struct SystemLaunchServices: LaunchServicesRegistering {
  package init() {}

  package func register(appAt url: URL) throws {
    // LSRegisterURL is the only public API that registers a bundle that lives outside /Applications.
    let status = LSRegisterURL(url as CFURL, true)
    guard status == noErr else { throw GameHostError.registrationFailed(status: status) }
  }
}

enum GameHostError: Error, Equatable {
  case helperMissing(String)
  case hostMissing
  case codesignFailed(exitCode: Int32)
  case registrationFailed(status: OSStatus)
}

private let log = Logger(subsystem: "io.github.tanzby.genshin-launcher", category: "wine")

/// Prepares Game Mode (LCH-022…026): installs the loader shim, builds and signs `GenshinLauncherGame.app`, registers
/// it. Any failure degrades to "no Game Mode" and the game still launches (LCH-023).
struct GameHostInstaller {
  let layout: WineLayout
  let runner: any ProcessRunning
  let launchServices: any LaunchServicesRegistering
  let helpers: GameHostHelpers?

  var bundleExecutable: URL { layout.gameHostApp.appending(path: "Contents/MacOS/wine") }
  var bundleHostCopy: URL { layout.gameHostApp.appending(path: "Contents/MacOS/.wine-host") }
  var infoPlist: URL { layout.gameHostApp.appending(path: "Contents/Info.plist") }
  var bundleIcon: URL { layout.gameHostApp.appending(path: "Contents/Resources/\(Self.iconName).icns") }

  /// The icon's file name without `.icns`, as `CFBundleIconFile` names it.
  static let iconName = "AppIcon"

  /// The four `GENSHIN_LAUNCHER_*` variables, or `[:]` when Game Mode is unavailable.
  func prepare(for recipe: LaunchRecipe) async -> [String: String] {
    do {
      guard let helpers else { throw GameHostError.helperMissing("helpers") }
      try await install(helpers: helpers, recipe: recipe)
      return [
        "GENSHIN_LAUNCHER_GAME_HOST_EXE": bundleExecutable.path,
        "GENSHIN_LAUNCHER_GAME_HOST_MATCH": recipe.gameExecutableName,
        "GENSHIN_LAUNCHER_GAME_HOST_DYLIB": helpers.dylib.path,
        "GENSHIN_LAUNCHER_GAMEHOST_LOG": layout.logsDirectory.appending(path: "gamehost.log").path,
      ]
    } catch {
      log.error("game host unavailable: \(String(describing: error), privacy: .public)")
      return [:]
    }
  }

  private func install(helpers: GameHostHelpers, recipe: LaunchRecipe) async throws {
    let fileManager = FileManager.default
    for helper in [helpers.shim, helpers.dylib] where !fileManager.fileExists(atPath: helper.path) {
      throw GameHostError.helperMissing(helper.lastPathComponent)
    }
    // 1. Loader shim. The first run renames the real `wine` to `wine-host`; a `wine` that already is the
    //    shim with no `wine-host` beside it would be moved away as the host, so refuse (LCH-024).
    let wine = layout.unixWine
    let host = layout.unixWineHost
    let wineIsShim = fileManager.fileExists(atPath: wine.path) && fileManager.contentsEqual(atPath: wine.path, andPath: helpers.shim.path)
    if !fileManager.fileExists(atPath: host.path) {
      guard fileManager.fileExists(atPath: wine.path), !wineIsShim else { throw GameHostError.hostMissing }
      // Stage the shim before the real loader is touched: a failed copy then leaves Wine fully intact.
      let staged = try stage(helpers.shim, beside: wine)
      try fileManager.moveItem(at: wine, to: host)
      do {
        try fileManager.moveItem(at: staged, to: wine)
      } catch {
        try? fileManager.moveItem(at: host, to: wine)
        try? fileManager.removeItem(at: staged)
        throw error
      }
    } else if !wineIsShim {
      try replace(helpers.shim, with: wine)
    }

    // 2. The bundle's executable is a copy of wine-host (never of `wine`, which is the shim now).
    var changed = false
    try fileManager.createDirectory(at: bundleExecutable.deletingLastPathComponent(), withIntermediateDirectories: true)
    let hostCopyCurrent =
      fileManager.fileExists(atPath: bundleHostCopy.path)
      && fileManager.fileExists(atPath: bundleExecutable.path)
      && fileManager.contentsEqual(atPath: bundleHostCopy.path, andPath: host.path)
    if !hostCopyCurrent {
      try replace(host, with: bundleExecutable)
      // The signing identifier must equal the bundle id, or every getaddrinfo stalls for ~35 s.
      let result = try await runner.run(
        URL(filePath: "/usr/bin/codesign"),
        arguments: ["-f", "-s", "-", "-i", GameSession.gameHostBundleIdentifier, bundleExecutable.path],
        environment: [:], workingDirectory: layout.root)
      guard result.exitCode == 0 else { throw GameHostError.codesignFailed(exitCode: result.exitCode) }
      changed = true
    }

    // 3. The launcher's icon, which the Game Mode notification shows. Copied only when it differs. It is
    //    cosmetic: a missing icon or a failed copy leaves the bundle without one but keeps Game Mode.
    if let icon = helpers.icon, fileManager.fileExists(atPath: icon.path),
      !fileManager.contentsEqual(atPath: icon.path, andPath: bundleIcon.path)
    {
      do {
        try fileManager.createDirectory(at: bundleIcon.deletingLastPathComponent(), withIntermediateDirectories: true)
        try replace(icon, with: bundleIcon)
        changed = true
      } catch {
        log.error("game host icon not copied: \(String(describing: error), privacy: .public)")
      }
    }

    // 4. Info.plist, rewritten only when its content differs.
    let hasIcon = fileManager.fileExists(atPath: bundleIcon.path)
    let plist = Self.infoPlist(displayName: recipe.gameDisplayName, iconFile: hasIcon ? Self.iconName : nil)
    let existing = (try? Data(contentsOf: infoPlist)).flatMap {
      try? PropertyListSerialization.propertyList(from: $0, format: nil) as? NSDictionary
    }
    if existing != plist as NSDictionary {
      let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
      try data.write(to: infoPlist, options: .atomic)
      changed = true
    }

    // 5. LaunchServices only needs to hear about it when something changed. The icon cache is keyed on the
    //    bundle's modification date, so bump it or a new icon is not shown.
    if changed {
      try? fileManager.setAttributes([.modificationDate: Date()], ofItemAtPath: layout.gameHostApp.path)
      do {
        try launchServices.register(appAt: layout.gameHostApp)
      } catch {
        // Make the next launch redo the registration instead of believing the bundle is current.
        try? fileManager.removeItem(at: infoPlist)
        throw error
      }
    }
    // The marker comes last: it says "signed, written and registered" (a failure above retries next launch).
    if !hostCopyCurrent { try replace(host, with: bundleHostCopy) }
  }

  static func infoPlist(displayName: String, iconFile: String?) -> [String: Any] {
    var plist: [String: Any] = [
      "CFBundleInfoDictionaryVersion": "6.0",
      "CFBundlePackageType": "APPL",
      "CFBundleExecutable": "wine",
      "CFBundleIdentifier": GameSession.gameHostBundleIdentifier,
      "CFBundleName": displayName,
      "CFBundleDisplayName": displayName,
      "CFBundleVersion": "1",
      "CFBundleShortVersionString": "1.0",
      "LSApplicationCategoryType": "public.app-category.games",
      "LSSupportsGameMode": true,
      "LSUIElement": true,
      "NSHighResolutionCapable": true,
      "NSPrincipalClass": "WineApplication",
    ]
    if let iconFile { plist["CFBundleIconFile"] = iconFile }
    return plist
  }

  /// Copies `source` next to `destination` under a temporary name, so the final step is a rename.
  private func stage(_ source: URL, beside destination: URL) throws -> URL {
    let fileManager = FileManager.default
    let staged = destination.deletingLastPathComponent().appending(path: ".\(destination.lastPathComponent).genshin-launcher-new")
    if (try? staged.checkResourceIsReachable()) == true { try fileManager.removeItem(at: staged) }
    do {
      try fileManager.copyItem(at: source, to: staged)
    } catch {
      try? fileManager.removeItem(at: staged)
      throw error
    }
    return staged
  }

  /// Atomic replace: a failed copy leaves the old `destination` in place.
  private func replace(_ source: URL, with destination: URL) throws {
    let fileManager = FileManager.default
    let staged = try stage(source, beside: destination)
    do {
      if (try? destination.checkResourceIsReachable()) == true {
        _ = try fileManager.replaceItemAt(destination, withItemAt: staged)
      } else {
        try fileManager.moveItem(at: staged, to: destination)
      }
    } catch {
      try? fileManager.removeItem(at: staged)
      throw error
    }
  }
}
