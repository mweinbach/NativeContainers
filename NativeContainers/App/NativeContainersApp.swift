import SwiftUI

@main
struct NativeContainersApp: App {
  @State private var model = AppModel()

  var body: some Scene {
    WindowGroup {
      RootView(model: model)
        .frame(minWidth: 940, minHeight: 620)
    }
    .defaultSize(width: 1180, height: 760)
    .commands {
      CommandGroup(after: .sidebar) {
        Button("Refresh All", systemImage: "arrow.clockwise") {
          Task { await model.refresh() }
        }
        .keyboardShortcut("r", modifiers: .command)
        .disabled(model.isRefreshing)
      }
    }

    Settings {
      SettingsView(model: model)
        .frame(width: 560, height: 360)
    }
  }
}
