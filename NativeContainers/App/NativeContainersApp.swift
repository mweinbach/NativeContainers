import SwiftUI

@main
struct NativeContainersApp: App {
  @State private var model = AppModel(services: AppCompositionRoot.live())

  @AppStorage(AppPreferenceKey.menuBarExtraInserted)
  private var isMenuBarExtraInserted = true

  var body: some Scene {
    Window("NativeContainers", id: "main") {
      RootView(model: model)
        .frame(minWidth: 940, minHeight: 620)
    }
    .defaultSize(width: 1180, height: 760)
    .commands {
      CommandGroup(after: .sidebar) {
        Button("Quick Open…", systemImage: "magnifyingglass") {
          model.presentQuickOpen()
        }
        .keyboardShortcut("k", modifiers: .command)

        Button("Refresh All", systemImage: "arrow.clockwise") {
          Task { await model.refresh() }
        }
        .keyboardShortcut("r", modifiers: .command)
        .disabled(model.isRefreshing)
      }
    }

    WindowGroup(
      "Terminal",
      id: "terminal-workspace",
      for: TerminalWindowRequest.self
    ) { $request in
      if let request {
        TerminalWorkspaceWindow(request: request, appModel: model)
      } else {
        ContentUnavailableView(
          "Choose a terminal target",
          systemImage: "terminal",
          description: Text("Open a container or Linux machine terminal from the main window.")
        )
      }
    }
    .defaultSize(width: 1_000, height: 700)

    Settings {
      SettingsView(model: model)
        .frame(width: 680, height: 700)
    }

    MenuBarExtra(
      "NativeContainers",
      systemImage: "shippingbox.fill",
      isInserted: AppExecutionContext.current.allowsPersistentSystemScenes
        ? $isMenuBarExtraInserted
        : .constant(false)
    ) {
      MenuBarQuickControlsView(model: model)
    }
    .menuBarExtraStyle(.window)
  }
}
