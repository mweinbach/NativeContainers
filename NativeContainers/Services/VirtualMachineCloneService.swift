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
  private let machineIdentifierGenerator: any MacVirtualMachineIdentifierGenerating

  init(
    fileManager: FileManager = .default,
    machineIdentifierGenerator: any MacVirtualMachineIdentifierGenerating =
      AppleMacVirtualMachineIdentifierGenerator()
  ) {
    self.fileManager = fileManager
    self.machineIdentifierGenerator = machineIdentifierGenerator
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
    try replaceMachineIdentifier(for: transaction)
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

  private func replaceMachineIdentifier(
    for transaction: VirtualMachineCloneTransaction
  ) throws {
    guard let path = transaction.clone.machineIdentifierPath else {
      throw VirtualMachineCloneError.invalidBundle(
        "the clone manifest has no machine identifier path"
      )
    }
    let resolver = MacVirtualMachineBundleResolver(
      rootURL: transaction.stagingBundleURL.deletingLastPathComponent(),
      fileManager: fileManager
    )
    let identifierURL = try resolver.resolveArtifact(
      path,
      named: "machineIdentifierPath",
      in: transaction.stagingBundleURL,
      writable: true
    )
    let sourceIdentifierData = try Data(contentsOf: identifierURL)
    let identifierData = try machineIdentifierGenerator.makeIdentifierData()
    guard identifierData != sourceIdentifierData,
      machineIdentifierGenerator.isValidIdentifierData(identifierData)
    else {
      throw VirtualMachineCloneError.invalidBundle(
        "the generated machine identifier is invalid or duplicates the source"
      )
    }

    try identifierData.write(to: identifierURL, options: .atomic)
    try fileManager.setAttributes(
      [.posixPermissions: 0o600],
      ofItemAtPath: identifierURL.path
    )
    let persistedData = try Data(contentsOf: identifierURL)
    guard persistedData == identifierData,
      machineIdentifierGenerator.isValidIdentifierData(persistedData)
    else {
      throw VirtualMachineCloneError.invalidBundle(
        "the fresh machine identifier did not persist safely"
      )
    }
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
