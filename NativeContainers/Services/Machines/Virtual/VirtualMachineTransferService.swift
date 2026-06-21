import Foundation

protocol VirtualMachinePackageTransferring: Sendable {
  func exportVirtualMachine(
    id: UUID,
    to destinationURL: URL
  ) async throws -> VirtualMachineExportReceipt

  func importVirtualMachine(
    from sourceURL: URL,
    mode: VirtualMachineImportMode
  ) async throws -> VirtualMachineManifest
}

protocol VirtualMachineExportSourceLeasing: Sendable {
  func acquireExportSource(id: UUID) async throws -> VirtualMachineExportSourceLease
}

protocol VirtualMachineImportStoring: Sendable {
  func beginImport(
    from sourceURL: URL,
    mode: VirtualMachineImportMode
  ) async throws -> VirtualMachineImportTransaction

  func commitImport(
    _ transaction: VirtualMachineImportTransaction
  ) async throws -> VirtualMachineManifest

  func abortImport(_ transaction: VirtualMachineImportTransaction) async throws
}

protocol SecurityScopedURLAccessing: Sendable {
  func acquireAccess(to url: URL) -> SecurityScopedURLAccessLease
}

final class VirtualMachineExportSourceLease: @unchecked Sendable {
  let manifest: VirtualMachineManifest
  let bundleURL: URL

  private let lock = NSLock()
  private var releaseHandler: (() -> Void)?

  init(
    manifest: VirtualMachineManifest,
    bundleURL: URL,
    release: @escaping () -> Void
  ) {
    self.manifest = manifest
    self.bundleURL = bundleURL
    releaseHandler = release
  }

  func release() {
    let handler = lock.withLock {
      let handler = releaseHandler
      releaseHandler = nil
      return handler
    }
    handler?()
  }

  deinit {
    release()
  }
}

final class SecurityScopedURLAccessLease: @unchecked Sendable {
  private let lock = NSLock()
  private var releaseHandler: (() -> Void)?

  init(url: URL) {
    guard url.startAccessingSecurityScopedResource() else { return }
    releaseHandler = {
      url.stopAccessingSecurityScopedResource()
    }
  }

  init(release: @escaping () -> Void) {
    releaseHandler = release
  }

  func release() {
    let handler = lock.withLock {
      let handler = releaseHandler
      releaseHandler = nil
      return handler
    }
    handler?()
  }

  deinit {
    release()
  }
}

struct BalancedSecurityScopedURLAccessService: SecurityScopedURLAccessing {
  func acquireAccess(to url: URL) -> SecurityScopedURLAccessLease {
    SecurityScopedURLAccessLease(url: url)
  }
}

actor VirtualMachineTransferService: VirtualMachinePackageTransferring {
  private let exportStore: any VirtualMachineExportSourceLeasing
  private let importStore: any VirtualMachineImportStoring
  private let preparer: any VirtualMachineBundlePreparing
  private let securityScopedAccess: any SecurityScopedURLAccessing
  private let fileManager: FileManager

  init(
    exportStore: any VirtualMachineExportSourceLeasing,
    importStore: any VirtualMachineImportStoring,
    preparer: any VirtualMachineBundlePreparing = VirtualMachineBundlePreparationService(),
    securityScopedAccess: any SecurityScopedURLAccessing =
      BalancedSecurityScopedURLAccessService(),
    fileManager: FileManager = .default
  ) {
    self.exportStore = exportStore
    self.importStore = importStore
    self.preparer = preparer
    self.securityScopedAccess = securityScopedAccess
    self.fileManager = fileManager
  }

  func exportVirtualMachine(
    id: UUID,
    to requestedDestinationURL: URL
  ) async throws -> VirtualMachineExportReceipt {
    let destinationURL = normalizedExportDestination(requestedDestinationURL)
    let destinationParent = destinationURL.deletingLastPathComponent()
    let accessLease = securityScopedAccess.acquireAccess(to: destinationParent)
    defer { accessLease.release() }

    try validateExportDestination(destinationURL)
    let sourceLease = try await exportStore.acquireExportSource(id: id)
    defer { sourceLease.release() }

    let operationID = UUID()
    let stagingURL = destinationParent.appending(
      path: ".NativeContainersExport-\(operationID.uuidString.lowercased()).partial",
      directoryHint: .isDirectory
    )
    guard !fileManager.fileExists(atPath: stagingURL.path) else {
      throw VirtualMachineTransferError.invalidDestination(
        "an export staging package already exists"
      )
    }
    guard !isDescendant(destinationParent, of: sourceLease.bundleURL),
      destinationURL.standardizedFileURL != sourceLease.bundleURL.standardizedFileURL
    else {
      throw VirtualMachineTransferError.invalidDestination(
        "the destination is inside the source package"
      )
    }

    do {
      try await preparer.prepare(
        VirtualMachineBundlePreparationRequest(
          sourceBundleURL: sourceLease.bundleURL,
          destinationBundleURL: stagingURL,
          sourceManifest: sourceLease.manifest,
          destinationManifest: sourceLease.manifest.portableRepresentation(),
          identityPolicy: .preserve,
          portability: .portable
        )
      )
      try Task.checkCancellation()
      guard !fileManager.fileExists(atPath: destinationURL.path) else {
        throw VirtualMachineTransferError.destinationExists(destinationURL)
      }
      try fileManager.moveItem(at: stagingURL, to: destinationURL)
      return VirtualMachineExportReceipt(
        machineID: sourceLease.manifest.id,
        destinationURL: destinationURL
      )
    } catch {
      try cleanup(
        stagingURL,
        operationError: error
      )
    }
  }

  func importVirtualMachine(
    from sourceURL: URL,
    mode: VirtualMachineImportMode
  ) async throws -> VirtualMachineManifest {
    let accessLease = securityScopedAccess.acquireAccess(to: sourceURL)
    defer { accessLease.release() }

    let transaction = try await importStore.beginImport(from: sourceURL, mode: mode)
    do {
      try await preparer.prepare(
        VirtualMachineBundlePreparationRequest(
          sourceBundleURL: transaction.sourceBundleURL,
          destinationBundleURL: transaction.stagingBundleURL,
          sourceManifest: transaction.source,
          destinationManifest: transaction.imported,
          identityPolicy: mode == .preserveIdentity ? .preserve : .regenerate,
          portability: .portable
        )
      )
      try Task.checkCancellation()
      return try await importStore.commitImport(transaction)
    } catch {
      do {
        try await importStore.abortImport(transaction)
      } catch let cleanupError {
        throw VirtualMachineTransferError.operationAndCleanupFailed(
          operation: error.localizedDescription,
          cleanup: cleanupError.localizedDescription
        )
      }
      throw error
    }
  }

  private func normalizedExportDestination(_ url: URL) -> URL {
    guard url.pathExtension.isEmpty else { return url.standardizedFileURL }
    return url.appendingPathExtension(VirtualMachineLibrary.bundleExtension)
      .standardizedFileURL
  }

  private func validateExportDestination(_ destinationURL: URL) throws {
    guard destinationURL.isFileURL,
      destinationURL.pathExtension.caseInsensitiveCompare(
        VirtualMachineLibrary.bundleExtension
      ) == .orderedSame
    else {
      throw VirtualMachineTransferError.invalidDestination(
        "exports must use the .\(VirtualMachineLibrary.bundleExtension) package extension"
      )
    }
    guard !fileManager.fileExists(atPath: destinationURL.path) else {
      throw VirtualMachineTransferError.destinationExists(destinationURL)
    }

    let parent = destinationURL.deletingLastPathComponent()
    do {
      let values = try parent.resourceValues(
        forKeys: [.isDirectoryKey, .isSymbolicLinkKey]
      )
      guard values.isDirectory == true, values.isSymbolicLink != true else {
        throw VirtualMachineTransferError.invalidDestination(
          "the destination folder is missing or symbolic"
        )
      }
    } catch let error as VirtualMachineTransferError {
      throw error
    } catch {
      throw VirtualMachineTransferError.invalidDestination(
        "the destination folder cannot be inspected"
      )
    }
  }

  private func cleanup(
    _ stagingURL: URL,
    operationError: Error
  ) throws -> Never {
    do {
      if fileManager.fileExists(atPath: stagingURL.path) {
        try fileManager.removeItem(at: stagingURL)
      }
    } catch {
      throw VirtualMachineTransferError.operationAndCleanupFailed(
        operation: operationError.localizedDescription,
        cleanup: error.localizedDescription
      )
    }
    throw operationError
  }

  private func isDescendant(_ candidate: URL, of directory: URL) -> Bool {
    let directoryComponents =
      directory.resolvingSymlinksInPath().standardizedFileURL.pathComponents
    let candidateComponents =
      candidate.resolvingSymlinksInPath().standardizedFileURL.pathComponents
    guard candidateComponents.count > directoryComponents.count else { return false }
    return candidateComponents.prefix(directoryComponents.count)
      .elementsEqual(directoryComponents)
  }
}

struct UnavailableVirtualMachineTransferService: VirtualMachinePackageTransferring {
  func exportVirtualMachine(
    id: UUID,
    to destinationURL: URL
  ) async throws -> VirtualMachineExportReceipt {
    throw VirtualMachineTransferError.unavailable
  }

  func importVirtualMachine(
    from sourceURL: URL,
    mode: VirtualMachineImportMode
  ) async throws -> VirtualMachineManifest {
    throw VirtualMachineTransferError.unavailable
  }
}
