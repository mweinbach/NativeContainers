import Foundation

protocol VirtualMachineCloning: Sendable {
  func cloneVirtualMachine(id: UUID, name: String) async throws -> VirtualMachineManifest
}

protocol VirtualMachineCloneStoring: Sendable {
  func beginClone(id: UUID, name: String) async throws -> VirtualMachineCloneTransaction
  func commitClone(_ transaction: VirtualMachineCloneTransaction) async throws
    -> VirtualMachineManifest
  func abortClone(_ transaction: VirtualMachineCloneTransaction) async throws
}

protocol VirtualMachineBundleCopying: Sendable {
  func copyBundle(for transaction: VirtualMachineCloneTransaction) async throws
}

actor VirtualMachineCloneService: VirtualMachineCloning {
  private let store: any VirtualMachineCloneStoring
  private let copier: any VirtualMachineBundleCopying

  init(
    store: any VirtualMachineCloneStoring,
    copier: any VirtualMachineBundleCopying = FileVirtualMachineBundleCopier()
  ) {
    self.store = store
    self.copier = copier
  }

  func cloneVirtualMachine(id: UUID, name: String) async throws -> VirtualMachineManifest {
    let transaction = try await store.beginClone(id: id, name: name)
    do {
      try Task.checkCancellation()
      try await copier.copyBundle(for: transaction)
      try Task.checkCancellation()
      return try await store.commitClone(transaction)
    } catch {
      do {
        try await store.abortClone(transaction)
      } catch let cleanupError {
        throw VirtualMachineCloneError.operationAndCleanupFailed(
          operation: error.localizedDescription,
          cleanup: cleanupError.localizedDescription
        )
      }
      throw error
    }
  }
}

struct FileVirtualMachineBundleCopier: VirtualMachineBundleCopying, @unchecked Sendable {
  private let preparer: any VirtualMachineBundlePreparing

  init(
    fileManager: FileManager = .default,
    transfer: any VirtualMachineBundleTransferring = CopyfileVirtualMachineBundleTransfer(),
    machineIdentifierGenerator: any MacVirtualMachineIdentifierGenerating =
      AppleMacVirtualMachineIdentifierGenerator()
  ) {
    preparer = VirtualMachineBundlePreparationService(
      transfer: transfer,
      inspector: FileVirtualMachineBundleInspector(fileManager: fileManager),
      sanitizer: FileVirtualMachineBundleSanitizer(fileManager: fileManager),
      machineIdentifierGenerator: machineIdentifierGenerator,
      fileManager: fileManager
    )
  }

  init(preparer: any VirtualMachineBundlePreparing) {
    self.preparer = preparer
  }

  func copyBundle(for transaction: VirtualMachineCloneTransaction) async throws {
    do {
      try await preparer.prepare(
        VirtualMachineBundlePreparationRequest(
          sourceBundleURL: transaction.sourceBundleURL,
          destinationBundleURL: transaction.stagingBundleURL,
          sourceManifest: transaction.source,
          destinationManifest: transaction.clone,
          identityPolicy: .regenerate,
          portability: .sameHost
        )
      )
    } catch is CancellationError {
      throw CancellationError()
    } catch let error as VirtualMachineBundleError {
      throw VirtualMachineCloneError.invalidBundle(error.localizedDescription)
    }
  }
}

struct UnavailableVirtualMachineCloneService: VirtualMachineCloning {
  func cloneVirtualMachine(id: UUID, name: String) async throws -> VirtualMachineManifest {
    throw VirtualMachineCloneError.unavailable
  }
}
