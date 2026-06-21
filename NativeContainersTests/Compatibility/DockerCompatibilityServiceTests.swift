import Testing

@testable import NativeContainers

@Suite("Docker compatibility service")
struct DockerCompatibilityServiceTests {
  @Test
  func extractsRuntimeSemverFromAppleHealthVersion() {
    #expect(
      AppleContainerHealthVersionChecker.semanticVersion(
        in: "container-apiserver version 1.0.0 (build: release, commit: ee848e3)"
      ) == "1.0.0"
    )
    #expect(
      AppleContainerHealthVersionChecker.semanticVersion(in: "unknown") == nil
    )
  }
}
