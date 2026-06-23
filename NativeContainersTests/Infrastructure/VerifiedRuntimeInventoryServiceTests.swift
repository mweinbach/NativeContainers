import Foundation
import Testing

@testable import NativeContainers

@Suite("Verified runtime inventory")
struct VerifiedRuntimeInventoryServiceTests {
  @Test
  func verifiesActiveRuntimeBeforeCallingInventoryTransport() async throws {
    let events = InventoryVerificationEventRecorder()
    let verifier = InventoryConnectionVerifierDouble(events: events)
    let base = InventoryLoaderDouble(events: events)
    let service = VerifiedRuntimeInventoryService(
      base: base,
      runtimeVerifier: verifier
    )

    let inventory = try await service.loadInventory()

    #expect(inventory == inventoryFixture())
    #expect(await events.values == ["verify", "inventory"])
    #expect(await verifier.callCount == 1)
    #expect(await base.callCount == 1)
  }

  @Test
  func failedVerificationNeverCallsInventoryTransport() async {
    let events = InventoryVerificationEventRecorder()
    let verifier = InventoryConnectionVerifierDouble(
      events: events,
      error: NativeRuntimeConnectionError.inactive
    )
    let base = InventoryLoaderDouble(events: events)
    let service = VerifiedRuntimeInventoryService(
      base: base,
      runtimeVerifier: verifier
    )

    await #expect(throws: NativeRuntimeConnectionError.inactive) {
      _ = try await service.loadInventory()
    }

    #expect(await events.values == ["verify"])
    #expect(await verifier.callCount == 1)
    #expect(await base.callCount == 0)
  }
}

private actor InventoryVerificationEventRecorder {
  private(set) var values: [String] = []

  func append(_ value: String) {
    values.append(value)
  }
}

private actor InventoryConnectionVerifierDouble:
  ActiveRuntimeConnectionVerifying
{
  private let events: InventoryVerificationEventRecorder
  private let error: NativeRuntimeConnectionError?
  private(set) var callCount = 0

  init(
    events: InventoryVerificationEventRecorder,
    error: NativeRuntimeConnectionError? = nil
  ) {
    self.events = events
    self.error = error
  }

  func verifyActiveRuntimeForConnection() async throws
    -> NativeRuntimeVerifiedDistribution
  {
    callCount += 1
    await events.append("verify")
    if let error { throw error }
    return NativeRuntimeVerifiedDistribution(
      origin: .appleOfficial,
      packageIdentifier: "com.apple.container-installer",
      version: "1.0.0",
      installRootURL: URL(filePath: "/usr/local", directoryHint: .isDirectory),
      builderArtifact: nil,
      serviceExecutablePaths: [:]
    )
  }
}

private actor InventoryLoaderDouble: ContainerInventoryLoading {
  private let events: InventoryVerificationEventRecorder
  private(set) var callCount = 0

  init(events: InventoryVerificationEventRecorder) {
    self.events = events
  }

  func loadInventory() async throws -> ContainerInventory {
    callCount += 1
    await events.append("inventory")
    return inventoryFixture()
  }
}

private func inventoryFixture() -> ContainerInventory {
  ContainerInventory(
    system: ContainerSystemInfo(
      version: "1.0.0",
      build: "release",
      commit: "verified",
      applicationRoot: URL(filePath: "/tmp/runtime"),
      installRoot: URL(filePath: "/usr/local")
    ),
    containers: [],
    images: [],
    volumes: [],
    networks: [],
    machines: []
  )
}
