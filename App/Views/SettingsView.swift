import AppKit
import Launcher
import SwiftUI
import Wine

/// The Settings window: a sidebar of four pages, like System Settings (#21).
struct SettingsView: View {
  enum Page: String, CaseIterable, Identifiable {
    case general, game, wine, advanced
    var id: Self { self }

    var title: LocalizedStringKey {
      switch self {
      case .general: "General"
      case .game: "Game"
      case .wine: "Wine"
      case .advanced: "Advanced"
      }
    }

    var symbol: String {
      switch self {
      case .general: "gearshape"
      case .game: "gamecontroller"
      case .wine: "wineglass"
      case .advanced: "wrench.and.screwdriver"
      }
    }
  }

  let dataDirectory: URL
  @State private var page: Page? = .general

  var body: some View {
    NavigationSplitView {
      List(Page.allCases, selection: $page) { page in
        Label(page.title, systemImage: page.symbol)
      }
      .navigationSplitViewColumnWidth(min: 150, ideal: 170, max: 200)
    } detail: {
      switch page ?? .general {
      case .general: GeneralPage()
      case .game: GamePage()
      case .wine: WinePage(dataDirectory: dataDirectory)
      case .advanced: AdvancedPage(dataDirectory: dataDirectory)
      }
    }
    .frame(width: 720, height: 460)
  }
}

private struct GeneralPage: View {
  @Environment(MainController.self) private var controller
  @State private var proxyDraft = ""
  @State private var proxyInvalid = false

  var body: some View {
    @Bindable var settings = controller.settings
    Form {
      Section("Game") {
        LabeledContent("Install Location") {
          HStack {
            Text(settings.gameDirectory?.path ?? String(localized: "Not chosen"))
              .foregroundStyle(.secondary)
              .lineLimit(1)
              .truncationMode(.middle)
            Button("Show in Finder") {
              if let url = settings.gameDirectory { NSWorkspace.shared.activateFileViewerSelecting([url]) }
            }
            .disabled(settings.gameDirectory == nil)
          }
        }
        Button("Check File Integrity") { Task { await controller.repair() } }
          .disabled(!controller.presentation.canRepair)
      }
      Section("Display & Input") {
        Toggle("Retina mode", isOn: $settings.retina)
        Toggle("Metal HUD", isOn: $settings.metalHUD)
        Toggle("Map left ⌘ to Control", isOn: $settings.leftCommandIsControl)
      }
      Section {
        Toggle("Use an HTTP proxy for the game", isOn: $settings.proxyEnabled)
        TextField("Proxy address", text: $proxyDraft, prompt: Text(verbatim: "127.0.0.1:7890"))
          .disabled(!settings.proxyEnabled)
          .onSubmit(commitProxy)
          .onChange(of: settings.proxyEnabled) { _, enabled in if !enabled { proxyInvalid = false } }
        if proxyInvalid {
          Text("Enter the address as host:port, for example 127.0.0.1:7890.")
            .font(.caption)
            .foregroundStyle(.red)
        }
      } header: {
        Text("Network")
      } footer: {
        Text("The proxy only applies to the game, not to downloads made by Yaagl.")
      }
      Section("Launcher") {
        LabeledContent("Version", value: Bundle.main.versionString)
      }
    }
    .formStyle(.grouped)
    .navigationTitle("General")
    .onAppear { proxyDraft = settings.proxyHost }
    .onDisappear(perform: commitProxy)
  }

  private func commitProxy() {
    let settings = controller.settings
    guard settings.proxyEnabled || !proxyDraft.isEmpty else { return }
    if proxyDraft.isEmpty {
      proxyInvalid = settings.proxyEnabled
    } else if settings.setProxyHost(proxyDraft) {
      proxyDraft = settings.proxyHost
      proxyInvalid = false
    } else {
      proxyInvalid = true
    }
  }
}

private struct GamePage: View {
  @Environment(MainController.self) private var controller
  @State private var widthDraft = 1920
  @State private var heightDraft = 1080

  var body: some View {
    @Bindable var settings = controller.settings
    Form {
      Section {
        Toggle("HDR", isOn: $settings.hdr)
        Toggle("MetalFX upscaling", isOn: $settings.metalFX)
        Toggle("Custom resolution", isOn: $settings.customResolutionEnabled)
        if settings.customResolutionEnabled {
          LabeledContent("Resolution") {
            HStack {
              TextField("Width", value: $widthDraft, format: .number.grouping(.never))
                .frame(width: 70)
              Text(verbatim: "×")
              TextField("Height", value: $heightDraft, format: .number.grouping(.never))
                .frame(width: 70)
            }
            .textFieldStyle(.roundedBorder)
            .labelsHidden()
            .multilineTextAlignment(.trailing)
          }
          if !(widthDraft > 0 && heightDraft > 0) {
            Text("Width and height must be positive whole numbers.")
              .font(.caption)
              .foregroundStyle(.red)
          }
        }
      } header: {
        Text("Graphics")
      } footer: {
        Text("Native full screen and Game Mode are always on.")
      }
    }
    .formStyle(.grouped)
    .navigationTitle("Game")
    .onAppear {
      widthDraft = settings.resolutionWidth
      heightDraft = settings.resolutionHeight
    }
    .onChange(of: widthDraft) { _, _ in settings.setResolution(width: widthDraft, height: heightDraft) }
    .onChange(of: heightDraft) { _, _ in settings.setResolution(width: widthDraft, height: heightDraft) }
  }
}

private struct WinePage: View {
  let dataDirectory: URL

  var body: some View {
    Form {
      Section("Runtime") {
        LabeledContent("Wine", value: WineRuntime.pinnedVersion)
        LabeledContent("DXMT", value: DXMTRelease.pinned.version)
      }
      Section("Tools") {
        Button("Show Wine Prefix in Finder") {
          reveal(WineLayout(root: dataDirectory).prefixDirectory)
        }
      }
    }
    .formStyle(.grouped)
    .navigationTitle("Wine")
  }
}

private struct AdvancedPage: View {
  let dataDirectory: URL

  var body: some View {
    Form {
      Section("Folders") {
        Button("Show Data Folder in Finder") { reveal(dataDirectory) }
        Button("Show Logs in Finder") { reveal(WineLayout(root: dataDirectory).logsDirectory) }
      }
      Section("Licenses") {
        ForEach(Credits.components, id: \.name) { component in
          LabeledContent(component.name, value: component.license)
        }
      }
    }
    .formStyle(.grouped)
    .navigationTitle("Advanced")
  }
}

/// Opens a folder in Finder, creating it first: the data folder does not exist before the first run.
private func reveal(_ directory: URL) {
  try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
  NSWorkspace.shared.open(directory)
}

extension Bundle {
  var versionString: String {
    let version = object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
    let build = object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "0"
    return "\(version) (\(build))"
  }
}
