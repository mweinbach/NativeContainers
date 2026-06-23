import Foundation
import Testing

@testable import NativeContainers

struct AppExecutionContextTests {
  @Test
  func detectsHostedTestAndPreviewProcessesFromEnvironment() {
    let standard = makeContext(environment: [:], macOSMajorVersion: 26)
    #expect(!standard.isRunningTests)
    #expect(!standard.isRunningPreviews)
    #expect(standard.allowsPersistentSystemScenes)
    #expect(standard.allowsSystemReportCollection)
    #expect(standard.allowsMenuBarControls)

    let test = makeContext(
      environment: ["XCTestConfigurationFilePath": "/tmp/config.xctestconfiguration"],
      macOSMajorVersion: 26
    )
    #expect(test.isRunningTests)
    #expect(!test.allowsPersistentSystemScenes)
    #expect(!test.allowsSystemReportCollection)
    #expect(!test.allowsMenuBarControls)

    let preview = makeContext(
      environment: ["XCODE_RUNNING_FOR_PREVIEWS": "1"],
      macOSMajorVersion: 26
    )
    #expect(preview.isRunningPreviews)
    #expect(!preview.allowsPersistentSystemScenes)
    #expect(!preview.allowsSystemReportCollection)
    #expect(!preview.allowsMenuBarControls)
  }

  @Test
  func appKitMenuBarControlsSupportEveryDeploymentOperatingSystem() {
    let macOS26 = makeContext(environment: [:], macOSMajorVersion: 26)
    #expect(macOS26.allowsMenuBarControls)

    let macOS27 = makeContext(environment: [:], macOSMajorVersion: 27)
    #expect(macOS27.allowsMenuBarControls)

    let laterRelease = makeContext(environment: [:], macOSMajorVersion: 28)
    #expect(laterRelease.allowsMenuBarControls)
  }

  @MainActor
  @Test
  func appKitControllerInstallsOnlyAfterExplicitStart() throws {
    let suiteName = "MenuBarQuickControlsControllerTests.\(UUID().uuidString)"
    let preferences = try #require(UserDefaults(suiteName: suiteName))
    defer { UserDefaults.standard.removePersistentDomain(forName: suiteName) }
    preferences.set(true, forKey: AppPreferenceKey.menuBarExtraInserted)

    let controller = MenuBarQuickControlsController(
      model: .preview,
      preferences: preferences
    )
    #expect(!controller.isVisible)

    controller.start(
      openMainWindow: { _ in },
      openSettings: {}
    )
    #expect(controller.isVisible)

    controller.stop()
    #expect(!controller.isVisible)
  }

  private func makeContext(
    environment: [String: String],
    macOSMajorVersion: Int
  ) -> AppExecutionContext {
    AppExecutionContext(
      environment: environment,
      operatingSystemVersion: OperatingSystemVersion(
        majorVersion: macOSMajorVersion,
        minorVersion: 0,
        patchVersion: 0
      )
    )
  }
}
