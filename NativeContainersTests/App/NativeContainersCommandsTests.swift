import AppKit
import Testing

@testable import NativeContainers

@Suite("Native app commands")
struct NativeContainersCommandsTests {
  @Test
  func navigationShortcutsCoverEveryManagedWorkspace() {
    let commands = WorkspaceNavigationCommand.allCases

    #expect(
      commands.map(\.destination) == [
        .overview,
        .containers,
        .composeProjects,
        .images,
        .builds,
        .volumes,
        .networks,
        .linuxMachines,
        .macOSVirtualMachines,
        .kubernetes,
      ]
    )
    #expect(String(commands.map(\.shortcutCharacter)) == "1234567890")
    #expect(Set(commands.map(\.shortcutCharacter)).count == commands.count)
    #expect(
      commands.map(\.keyEquivalent.character)
        == commands.map(\.shortcutCharacter)
    )
    #expect(!commands.map(\.destination).contains(.settings))
  }

  @Test
  func sidebarDestinationsUseAvailableSystemSymbols() {
    for destination in SidebarDestination.allCases {
      #expect(
        NSImage(
          systemSymbolName: destination.systemImage,
          accessibilityDescription: nil
        ) != nil,
        "Missing SF Symbol for \(destination.rawValue): \(destination.systemImage)"
      )
    }
  }
}
