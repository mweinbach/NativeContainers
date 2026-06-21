import SwiftUI

struct NativeContainersCommands: Commands {
  let model: AppModel

  var body: some Commands {
    SidebarCommands()
    ToolbarCommands()

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

    CommandMenu("Navigate") {
      ForEach(WorkspaceNavigationCommand.allCases) { command in
        Button {
          model.selectSidebarDestination(command.destination)
        } label: {
          Label(
            command.destination.title,
            systemImage: command.destination.systemImage
          )
        }
        .keyboardShortcut(command.keyEquivalent, modifiers: .command)
        .disabled(!model.canNavigate(to: command.destination.workspaceRoute))
      }
    }
  }
}

enum WorkspaceNavigationCommand: CaseIterable, Identifiable {
  case overview
  case containers
  case composeProjects
  case images
  case builds
  case volumes
  case networks
  case linuxMachines
  case virtualMachines

  var id: Self { self }

  var destination: SidebarDestination {
    switch self {
    case .overview: .overview
    case .containers: .containers
    case .composeProjects: .composeProjects
    case .images: .images
    case .builds: .builds
    case .volumes: .volumes
    case .networks: .networks
    case .linuxMachines: .linuxMachines
    case .virtualMachines: .macOSVirtualMachines
    }
  }

  var shortcutCharacter: Character {
    switch self {
    case .overview: "1"
    case .containers: "2"
    case .composeProjects: "3"
    case .images: "4"
    case .builds: "5"
    case .volumes: "6"
    case .networks: "7"
    case .linuxMachines: "8"
    case .virtualMachines: "9"
    }
  }

  var keyEquivalent: KeyEquivalent {
    KeyEquivalent(shortcutCharacter)
  }
}
