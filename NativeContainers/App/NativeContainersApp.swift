import SwiftUI

@main
struct NativeContainersApp: App {
  @State private var model: AppModel
  @State private var menuBarQuickControls: MenuBarQuickControlsController

  init() {
    let model = AppModel(services: AppCompositionRoot.live())
    _model = State(initialValue: model)
    _menuBarQuickControls = State(
      initialValue: MenuBarQuickControlsController(model: model)
    )
  }

  var body: some Scene {
    Window("NativeContainers", id: "main") {
      RootView(model: model)
        .frame(minWidth: 940, minHeight: 620)
        .background {
          MenuBarQuickControlsInstaller(
            model: model,
            controller: menuBarQuickControls
          )
        }
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

    WindowGroup(
      "Virtual Machine",
      id: VirtualMachineConsoleWindowRequest.windowGroupID,
      for: VirtualMachineConsoleWindowRequest.self
    ) { $request in
      if let request {
        VirtualMachineConsoleWindow(request: request, appModel: model)
      } else {
        ContentUnavailableView(
          "Choose a Virtual Machine",
          systemImage: "display",
          description: Text(
            "Open a macOS or Linux virtual machine from the main window."
          )
        )
      }
    }
    .defaultSize(width: 1_180, height: 760)

    Settings {
      SettingsView(model: model)
        .frame(width: 680, height: 700)
    }

  }
}
