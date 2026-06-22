import Foundation

struct AppExecutionContext: Sendable {
  // MenuBarExtra continuously invalidates the app graph on macOS 27.
  // Keep newer runtimes disabled until the framework behavior is revalidated.
  private static let latestMenuBarExtraCompatibleMajorVersion = 26

  let isRunningTests: Bool
  let isRunningPreviews: Bool
  let operatingSystemVersion: OperatingSystemVersion

  var allowsPersistentSystemScenes: Bool {
    !isRunningTests && !isRunningPreviews
  }

  var supportsMenuBarExtra: Bool {
    operatingSystemVersion.majorVersion <= Self.latestMenuBarExtraCompatibleMajorVersion
  }

  var allowsMenuBarExtra: Bool {
    allowsPersistentSystemScenes && supportsMenuBarExtra
  }

  init(
    environment: [String: String],
    operatingSystemVersion: OperatingSystemVersion
  ) {
    isRunningTests = environment["XCTestConfigurationFilePath"] != nil
    isRunningPreviews = environment["XCODE_RUNNING_FOR_PREVIEWS"] == "1"
    self.operatingSystemVersion = operatingSystemVersion
  }

  static let current = AppExecutionContext(
    environment: ProcessInfo.processInfo.environment,
    operatingSystemVersion: ProcessInfo.processInfo.operatingSystemVersion
  )
}
