import Foundation
import Testing

@testable import NativeContainers

@Suite(.serialized)
struct LiveAppleContainerSmokeTests {
  @Test(
    .enabled(
      if: ProcessInfo.processInfo.environment["NATIVECONTAINERS_LIVE_TESTS"] == "1",
      "Set NATIVECONTAINERS_LIVE_TESTS=1 with Apple container services running."
    )
  )
  func createInspectAndDeleteStoppedContainer() async throws {
    let service = AppleContainerService()
    let id = "nativecontainers-smoke-\(UUID().uuidString.lowercased().prefix(8))"
    let request = try ContainerCreationRequest(
      name: id,
      imageReference: "docker.io/library/alpine:3.21",
      cpuCount: 1,
      memoryBytes: 256 * ContainerCreationRequest.bytesPerMiB,
      arguments: ["/bin/true"],
      startAfterCreation: false
    )

    do {
      try await service.createContainer(request: request) { _ in }
      let created = try await service.loadInventory().containers.first { $0.id == id }
      #expect(created?.state == .stopped)
      #expect(created?.cpuCount == 1)
      #expect(created?.memoryBytes == 256 * ContainerCreationRequest.bytesPerMiB)
      try await service.deleteContainer(id: id)
      let remains = try await service.loadInventory().containers.contains { $0.id == id }
      #expect(!remains)
    } catch {
      try? await service.deleteContainer(id: id)
      throw error
    }
  }
}
