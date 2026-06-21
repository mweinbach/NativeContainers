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
      ]
    )
    #expect(String(commands.map(\.shortcutCharacter)) == "123456789")
    #expect(Set(commands.map(\.shortcutCharacter)).count == commands.count)
    #expect(
      commands.map(\.keyEquivalent.character)
        == commands.map(\.shortcutCharacter)
    )
    #expect(!commands.map(\.destination).contains(.settings))
  }
}
