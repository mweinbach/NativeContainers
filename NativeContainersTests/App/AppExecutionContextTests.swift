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
    #expect(standard.allowsMenuBarExtra)

    let test = makeContext(
      environment: ["XCTestConfigurationFilePath": "/tmp/config.xctestconfiguration"],
      macOSMajorVersion: 26
    )
    #expect(test.isRunningTests)
    #expect(!test.allowsPersistentSystemScenes)
    #expect(!test.allowsSystemReportCollection)
    #expect(!test.allowsMenuBarExtra)

    let preview = makeContext(
      environment: ["XCODE_RUNNING_FOR_PREVIEWS": "1"],
      macOSMajorVersion: 26
    )
    #expect(preview.isRunningPreviews)
    #expect(!preview.allowsPersistentSystemScenes)
    #expect(!preview.allowsSystemReportCollection)
    #expect(!preview.allowsMenuBarExtra)
  }

  @Test
  func limitsMenuBarExtraToVerifiedOperatingSystemVersions() {
    let macOS26 = makeContext(environment: [:], macOSMajorVersion: 26)
    #expect(macOS26.supportsMenuBarExtra)
    #expect(macOS26.allowsMenuBarExtra)

    let macOS27 = makeContext(environment: [:], macOSMajorVersion: 27)
    #expect(!macOS27.supportsMenuBarExtra)
    #expect(!macOS27.allowsMenuBarExtra)

    let laterRelease = makeContext(environment: [:], macOSMajorVersion: 28)
    #expect(!laterRelease.supportsMenuBarExtra)
    #expect(!laterRelease.allowsMenuBarExtra)
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
