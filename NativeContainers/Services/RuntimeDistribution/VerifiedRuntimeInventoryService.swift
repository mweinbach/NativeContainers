import Foundation

struct VerifiedRuntimeInventoryService: ContainerInventoryLoading {
  private let base: any ContainerInventoryLoading
  private let runtimeVerifier: any ActiveRuntimeConnectionVerifying

  init(
    base: any ContainerInventoryLoading,
    runtimeVerifier: any ActiveRuntimeConnectionVerifying
  ) {
    self.base = base
    self.runtimeVerifier = runtimeVerifier
  }

  func loadInventory() async throws -> ContainerInventory {
    _ = try await runtimeVerifier.verifyActiveRuntimeForConnection()
    return try await base.loadInventory()
  }

  func usesRuntimeVerifier(
    _ candidate: any ActiveRuntimeConnectionVerifying
  ) -> Bool {
    ObjectIdentifier(runtimeVerifier) == ObjectIdentifier(candidate)
  }
}
