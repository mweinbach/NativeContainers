import Foundation

struct AppExecutionContext: Sendable {
  let isRunningTests: Bool
  let isRunningPreviews: Bool
  let operatingSystemVersion: OperatingSystemVersion

  var allowsPersistentSystemScenes: Bool {
    !isRunningTests && !isRunningPreviews
  }

  var allowsSystemReportCollection: Bool {
    !isRunningTests && !isRunningPreviews
  }

  var allowsMenuBarControls: Bool {
    allowsPersistentSystemScenes
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
