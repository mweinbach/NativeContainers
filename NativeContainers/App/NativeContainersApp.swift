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
      NativeContainersCommands(model: model)
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
          description: Text(
            "Open a container, Linux machine, or Kubernetes Pod terminal from the main window."
          )
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
      isInserted: AppExecutionContext.current.allowsMenuBarExtra
        ? $isMenuBarExtraInserted
        : .constant(false)
    ) {
      MenuBarQuickControlsView(model: model)
    }
    .menuBarExtraStyle(.window)
  }
}
