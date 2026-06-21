import Testing

@testable import NativeContainers

struct AppExecutionContextTests {
  @Test
  func detectsHostedTestAndPreviewProcessesFromEnvironment() {
    let standard = AppExecutionContext(environment: [:])
    #expect(!standard.isRunningTests)
    #expect(!standard.isRunningPreviews)
    #expect(standard.allowsPersistentSystemScenes)

    let test = AppExecutionContext(
      environment: ["XCTestConfigurationFilePath": "/tmp/config.xctestconfiguration"]
    )
    #expect(test.isRunningTests)
    #expect(!test.allowsPersistentSystemScenes)

    let preview = AppExecutionContext(
      environment: ["XCODE_RUNNING_FOR_PREVIEWS": "1"]
    )
    #expect(preview.isRunningPreviews)
    #expect(!preview.allowsPersistentSystemScenes)
  }
}
