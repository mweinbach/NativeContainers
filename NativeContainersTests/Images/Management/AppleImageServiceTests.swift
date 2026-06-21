import Testing

@testable import NativeContainers

@Suite("Apple image service")
struct AppleImageServiceTests {
  @Test
  func pullValidationRejectsMissingReferenceBeforeRuntimeAccess() async {
    let service = AppleImageService()

    await #expect(throws: ImageManagementError.missingReference) {
      try await service.prepareImagePull(
        reference: "   ",
        platform: .current,
        transport: .automatic,
        unpackAfterPull: true,
        maxConcurrentDownloads: 3
      )
    }
  }

  @Test
  func pullValidationRejectsInvalidConcurrencyBeforeRuntimeAccess() async {
    let service = AppleImageService()

    await #expect(throws: ImageManagementError.invalidConcurrentDownloads) {
      try await service.prepareImagePull(
        reference: "alpine:latest",
        platform: .current,
        transport: .automatic,
        unpackAfterPull: true,
        maxConcurrentDownloads: 0
      )
    }
  }

  @Test
  func compatibilityFacadeForwardsImageValidation() async {
    let service = AppleContainerService()

    await #expect(throws: ImageManagementError.missingReference) {
      try await service.prepareImagePush(
        reference: "",
        platform: .current,
        transport: .automatic
      )
    }
  }
}
