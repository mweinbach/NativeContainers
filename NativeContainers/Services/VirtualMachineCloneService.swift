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
  private let fileManager: FileManager

  init(fileManager: FileManager = .default) {
    self.fileManager = fileManager
  }

  func copyBundle(for transaction: VirtualMachineCloneTransaction) async throws {
    try Task.checkCancellation()
    try rejectSymbolicLinks(in: transaction.sourceBundleURL)
    try fileManager.copyItem(
      at: transaction.sourceBundleURL,
      to: transaction.stagingBundleURL
    )
    try Task.checkCancellation()
    try removeTransientState(from: transaction.stagingBundleURL)
    try write(transaction.clone, to: transaction.stagingBundleURL)
    try Task.checkCancellation()
  }

  private func rejectSymbolicLinks(in directoryURL: URL) throws {
    let entries = try fileManager.contentsOfDirectory(
      at: directoryURL,
      includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
      options: []
    )
    for entry in entries {
      let values = try entry.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
      guard values.isSymbolicLink != true else {
        throw VirtualMachineCloneError.invalidBundle(
          "\(entry.lastPathComponent) is a symbolic link"
        )
      }
      if values.isDirectory == true {
        try rejectSymbolicLinks(in: entry)
      }
    }
  }

  private func removeTransientState(from bundleURL: URL) throws {
    let entries = try fileManager.contentsOfDirectory(
      at: bundleURL,
      includingPropertiesForKeys: nil,
      options: []
    )
    for entry in entries where isTransient(entry.lastPathComponent) {
      try fileManager.removeItem(at: entry)
    }
  }

  private func isTransient(_ name: String) -> Bool {
    name == VirtualMachineLibrary.runtimeLockFilename
      || name == VirtualMachineLibrary.runtimeOwnerFilename
      || name == MacVirtualMachineSavedStateStore.directoryName
      || name.hasPrefix(VirtualMachineLibrary.installationStagingPrefix)
      || name.hasPrefix(MacVirtualMachineSavedStateStore.stagingPrefix)
  }

  private func write(_ manifest: VirtualMachineManifest, to bundleURL: URL) throws {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    let data = try encoder.encode(manifest)
    try data.write(
      to: bundleURL.appending(path: VirtualMachineLibrary.manifestFilename),
      options: .atomic
    )
  }
}

struct UnavailableVirtualMachineCloneService: VirtualMachineCloning {
  func cloneVirtualMachine(id: UUID, name: String) async throws -> VirtualMachineManifest {
    throw VirtualMachineCloneError.unavailable
  }
}
