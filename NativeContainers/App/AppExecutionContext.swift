import Foundation

struct AppExecutionContext: Sendable {
  let isRunningTests: Bool
  let isRunningPreviews: Bool

  var allowsPersistentSystemScenes: Bool {
    !isRunningTests && !isRunningPreviews
  }

  init(environment: [String: String]) {
    isRunningTests = environment["XCTestConfigurationFilePath"] != nil
    isRunningPreviews = environment["XCODE_RUNNING_FOR_PREVIEWS"] == "1"
  }

  static let current = AppExecutionContext(
    environment: ProcessInfo.processInfo.environment
  )
}
