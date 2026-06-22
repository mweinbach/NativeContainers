import Foundation
import Testing

@testable import NativeContainers

struct VirtualMachineCloneServiceTests {
  @Test
  func cloneRejectsPendingDiskMigrationJournal() async throws {
    let root = temporaryRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let library = VirtualMachineLibrary(rootURL: root)
    let source = try await makeStoppedMachine(
      library: library,
      root: root,
      name: "Pending Migration"
    )
    let sourceBundle = bundleURL(root: root, id: source.id)
    try Data("pending".utf8).write(
      to: sourceBundle.appending(
        path: VirtualMachineDiskImageReplacementArtifacts.journalFilename
      )
    )

    await #expect(throws: VirtualMachineCloneError.self) {
      _ = try await VirtualMachineCloneService(store: library)
        .cloneVirtualMachine(id: source.id, name: "Unsafe Copy")
    }

    #expect(try await library.list() == [source])
    try expectNoCloneStagingBundles(in: root)
  }

  @Test
  func clonesStoppedBundleAndRemovesTransientRuntimeState() async throws {
    let root = temporaryRoot()
    defer { try? FileManager.default.removeItem(at: root) }

    let library = VirtualMachineLibrary(rootURL: root)
    let source = try await makeStoppedMachine(
      library: library,
      root: root,
      name: "Source Mac",
      microphoneEnabled: true
    )
    let sourceBundle = bundleURL(root: root, id: source.id)
    let sourceDisk = sourceBundle.appending(path: source.diskImagePath)
    let diskHandle = try FileHandle(forWritingTo: sourceDisk)
    try diskHandle.seek(toOffset: 4_096)
    try diskHandle.write(contentsOf: Data("clone-sentinel".utf8))
    try diskHandle.close()

    let savedState = sourceBundle.appending(
      path: MacVirtualMachineSavedStateStore.directoryName,
      directoryHint: .isDirectory
    )
    try FileManager.default.createDirectory(at: savedState, withIntermediateDirectories: false)
    try Data("saved-state".utf8).write(
      to: savedState.appending(path: MacVirtualMachineSavedStateStore.stateFilename)
    )
    let savedStateStaging = sourceBundle.appending(
      path: "\(MacVirtualMachineSavedStateStore.stagingPrefix)stale.partial",
      directoryHint: .isDirectory
    )
    try FileManager.default.createDirectory(
      at: savedStateStaging,
      withIntermediateDirectories: false
    )
    let installationStaging = sourceBundle.appending(
      path: "\(VirtualMachineLibrary.installationStagingPrefix)stale.partial",
      directoryHint: .isDirectory
    )
    try FileManager.default.createDirectory(
      at: installationStaging,
      withIntermediateDirectories: false
    )
    _ = FileManager.default.createFile(
      atPath: sourceBundle.appending(path: VirtualMachineLibrary.runtimeOwnerFilename).path,
      contents: Data("owner".utf8)
    )
    try Data("keep-me".utf8).write(to: sourceBundle.appending(path: "Notes.txt"))

    let service = VirtualMachineCloneService(store: library)
    let clone = try await service.cloneVirtualMachine(
      id: source.id,
      name: "Source Mac Copy"
    )

    let machines = try await library.list()
    let cloneBundle = bundleURL(root: root, id: clone.id)
    #expect(machines.map(\.id).contains(source.id))
    #expect(machines.map(\.id).contains(clone.id))
    #expect(clone.id != source.id)
    #expect(clone.name == "Source Mac Copy")
    #expect(clone.installState == .stopped)
    #expect(clone.resources == source.resources)
    #expect(clone.diskImagePath == source.diskImagePath)
    #expect(clone.auxiliaryStoragePath == source.auxiliaryStoragePath)
    #expect(clone.hardwareModelPath == source.hardwareModelPath)
    #expect(clone.machineIdentifierPath == source.machineIdentifierPath)
    #expect(clone.installationOperationID == nil)
    #expect(clone.installationFailure == nil)
    #expect(source.effectiveAudioConfiguration.isMicrophoneEnabled)
    #expect(clone.audioConfiguration == nil)
    #expect(clone.effectiveAudioConfiguration == .disconnected)
    #expect(
      try Data(contentsOf: cloneBundle.appending(path: "Notes.txt")) == Data("keep-me".utf8)
    )

    let cloneDisk = cloneBundle.appending(path: clone.diskImagePath)
    let cloneDiskHandle = try FileHandle(forReadingFrom: cloneDisk)
    try cloneDiskHandle.seek(toOffset: 4_096)
    let copiedSentinel = try cloneDiskHandle.read(upToCount: "clone-sentinel".utf8.count)
    try cloneDiskHandle.close()
    #expect(copiedSentinel == Data("clone-sentinel".utf8))

    let sourceIdentifierPath = try #require(source.machineIdentifierPath)
    let cloneIdentifierPath = try #require(clone.machineIdentifierPath)
    let sourceIdentifierData = try Data(
      contentsOf: sourceBundle.appending(path: sourceIdentifierPath)
    )
    let cloneIdentifierData = try Data(
      contentsOf: cloneBundle.appending(path: cloneIdentifierPath)
    )
    #expect(cloneIdentifierData != sourceIdentifierData)
    #expect(
      AppleMacVirtualMachineIdentifierGenerator().isValidIdentifierData(cloneIdentifierData)
    )

    #expect(
      !FileManager.default.fileExists(
        atPath: cloneBundle.appending(path: VirtualMachineLibrary.runtimeLockFilename).path
      )
    )
    #expect(
      !FileManager.default.fileExists(
        atPath: cloneBundle.appending(path: VirtualMachineLibrary.runtimeOwnerFilename).path
      )
    )
    #expect(
      !FileManager.default.fileExists(
        atPath: cloneBundle.appending(
          path: MacVirtualMachineSavedStateStore.directoryName
        ).path
      )
    )
    #expect(
      !FileManager.default.fileExists(
        atPath: cloneBundle.appending(path: savedStateStaging.lastPathComponent).path))
    #expect(
      !FileManager.default.fileExists(
        atPath: cloneBundle.appending(path: installationStaging.lastPathComponent).path))

    #expect(FileManager.default.fileExists(atPath: savedState.path))
    #expect(FileManager.default.fileExists(atPath: savedStateStaging.path))
    #expect(FileManager.default.fileExists(atPath: installationStaging.path))
    try expectNoCloneStagingBundles(in: root)
  }

  @Test
  func clonesStoppedLinuxBundleWithFreshPlatformAndNetworkIdentity() async throws {
    let root = temporaryRoot()
    defer { try? FileManager.default.removeItem(at: root) }

    let library = VirtualMachineLibrary(rootURL: root)
    let source = try await makeStoppedLinuxMachine(
      library: library,
      root: root,
      name: "Source Linux",
      networkAttachment: .shared
    )
    let sourceBundle = bundleURL(root: root, id: source.id)
    let sourceConfiguration = try #require(source.linuxConfiguration)
    let sourceIdentifier = try Data(
      contentsOf: sourceBundle.appending(path: sourceConfiguration.machineIdentifierPath)
    )

    let clone = try await VirtualMachineCloneService(store: library)
      .cloneVirtualMachine(id: source.id, name: "Source Linux Copy")

    let cloneBundle = bundleURL(root: root, id: clone.id)
    let cloneConfiguration = try #require(clone.linuxConfiguration)
    let cloneIdentifier = try Data(
      contentsOf: cloneBundle.appending(path: cloneConfiguration.machineIdentifierPath)
    )
    let identityGenerator = AppleLinuxVirtualMachineIdentityGenerator()
    #expect(clone.id != source.id)
    #expect(clone.name == "Source Linux Copy")
    #expect(clone.guest == .linux)
    #expect(clone.installState == .stopped)
    #expect(cloneConfiguration.installationMediaPath == nil)
    #expect(cloneConfiguration.sharesClipboard == sourceConfiguration.sharesClipboard)
    #expect(clone.effectiveNetworkConfiguration.attachment == .shared)
    #expect(clone.networkConfiguration == source.networkConfiguration)
    #expect(cloneIdentifier != sourceIdentifier)
    #expect(identityGenerator.isValidIdentifierData(cloneIdentifier))
    #expect(
      cloneConfiguration.macAddress.caseInsensitiveCompare(sourceConfiguration.macAddress)
        != .orderedSame
    )
    #expect(identityGenerator.isValidMACAddress(cloneConfiguration.macAddress))
    #expect(
      try Data(
        contentsOf: cloneBundle.appending(path: cloneConfiguration.efiVariableStorePath)
      ) == Data("efi-state".utf8)
    )
    #expect(Set(try await library.list().map(\.id)) == Set([source.id, clone.id]))
    try expectNoCloneStagingBundles(in: root)
  }

  @Test
  func copyFailureAbortsTransactionAndReleasesLibraryLocks() async throws {
    let root = temporaryRoot()
    defer { try? FileManager.default.removeItem(at: root) }

    let library = VirtualMachineLibrary(rootURL: root)
    let source = try await makeStoppedMachine(
      library: library,
      root: root,
      name: "Retryable Mac"
    )
    let failing = VirtualMachineCloneService(
      store: library,
      copier: PartialFailingVirtualMachineBundleCopier()
    )

    await #expect(throws: VirtualMachineCloneTestError.expected) {
      _ = try await failing.cloneVirtualMachine(id: source.id, name: "Failed Copy")
    }
    #expect(try await library.list() == [source])
    try expectNoCloneStagingBundles(in: root)

    let retry = VirtualMachineCloneService(store: library)
    let clone = try await retry.cloneVirtualMachine(id: source.id, name: "Recovered Copy")
    #expect(clone.name == "Recovered Copy")
  }

  @Test
  func cancellationAbortsPartialCopyAndReleasesLibraryLocks() async throws {
    let root = temporaryRoot()
    defer { try? FileManager.default.removeItem(at: root) }

    let library = VirtualMachineLibrary(rootURL: root)
    let source = try await makeStoppedMachine(
      library: library,
      root: root,
      name: "Cancellable Mac"
    )
    let copier = CancellableBlockingVirtualMachineBundleCopier()
    let service = VirtualMachineCloneService(store: library, copier: copier)
    let cloneTask = Task {
      try await service.cloneVirtualMachine(id: source.id, name: "Cancelled Copy")
    }

    await copier.waitUntilStarted()
    cloneTask.cancel()

    await #expect(throws: CancellationError.self) {
      _ = try await cloneTask.value
    }
    #expect(try await library.list() == [source])
    try expectNoCloneStagingBundles(in: root)

    let retry = VirtualMachineCloneService(store: library)
    let clone = try await retry.cloneVirtualMachine(id: source.id, name: "After Cancel")
    #expect(clone.name == "After Cancel")
  }

  @Test
  func refusesToCloneMachineOwnedByARuntimeSession() async throws {
    let root = temporaryRoot()
    defer { try? FileManager.default.removeItem(at: root) }

    let library = VirtualMachineLibrary(rootURL: root)
    let source = try await makeStoppedMachine(
      library: library,
      root: root,
      name: "Running Mac"
    )
    let runtimeLease = try await library.acquireMacOSRuntime(id: source.id)
    defer { runtimeLease.release() }
    let service = VirtualMachineCloneService(store: library)

    await #expect(throws: MacVirtualMachineRuntimeError.ownedElsewhere(source.id)) {
      _ = try await service.cloneVirtualMachine(id: source.id, name: "Unsafe Copy")
    }
    #expect(try await library.list() == [source])
    try expectNoCloneStagingBundles(in: root)
  }

  @Test
  func refusesToCloneLinuxMachineOwnedByARuntimeSession() async throws {
    let root = temporaryRoot()
    defer { try? FileManager.default.removeItem(at: root) }

    let library = VirtualMachineLibrary(rootURL: root)
    let source = try await makeStoppedLinuxMachine(
      library: library,
      root: root,
      name: "Running Linux"
    )
    let runtimeLease = try await library.acquireLinuxRuntime(id: source.id)
    defer { runtimeLease.release() }

    await #expect(throws: LinuxVirtualMachineRuntimeError.ownedElsewhere(source.id)) {
      _ = try await VirtualMachineCloneService(store: library)
        .cloneVirtualMachine(id: source.id, name: "Unsafe Linux Copy")
    }
    #expect(try await library.list() == [source])
    try expectNoCloneStagingBundles(in: root)
  }

  @Test
  func storeRejectsCopierThatPreservesTheSourceMachineIdentifier() async throws {
    let root = temporaryRoot()
    defer { try? FileManager.default.removeItem(at: root) }

    let library = VirtualMachineLibrary(rootURL: root)
    let source = try await makeStoppedMachine(
      library: library,
      root: root,
      name: "Identity Source"
    )
    let transaction = try await library.beginClone(id: source.id, name: "Unsafe Identity Copy")
    try FileManager.default.copyItem(
      at: transaction.sourceBundleURL,
      to: transaction.stagingBundleURL
    )
    let copiedRuntimeLock = transaction.stagingBundleURL.appending(
      path: VirtualMachineLibrary.runtimeLockFilename
    )
    if FileManager.default.fileExists(atPath: copiedRuntimeLock.path) {
      try FileManager.default.removeItem(at: copiedRuntimeLock)
    }
    try write(transaction.clone, to: transaction.stagingBundleURL)

    await #expect(throws: VirtualMachineCloneError.self) {
      _ = try await library.commitClone(transaction)
    }
    try await library.abortClone(transaction)

    #expect(try await library.list() == [source])
    try expectNoCloneStagingBundles(in: root)
  }

  @Test
  func refusesToCloneAnUninstalledDraft() async throws {
    let root = temporaryRoot()
    defer { try? FileManager.default.removeItem(at: root) }

    let library = VirtualMachineLibrary(rootURL: root)
    let resources = try testResources()
    let draft = try await library.createDraft(
      name: "Draft",
      guest: .macOS,
      resources: resources
    )
    let service = VirtualMachineCloneService(store: library)

    await #expect(throws: VirtualMachineCloneError.invalidSourceState(.draft)) {
      _ = try await service.cloneVirtualMachine(id: draft.id, name: "Draft Copy")
    }
  }

  @Test
  func rejectsSymbolicLinksAndLeavesTheSourceUntouched() async throws {
    let root = temporaryRoot()
    defer { try? FileManager.default.removeItem(at: root) }

    let library = VirtualMachineLibrary(rootURL: root)
    let source = try await makeStoppedMachine(
      library: library,
      root: root,
      name: "Safe Mac"
    )
    let sourceBundle = bundleURL(root: root, id: source.id)
    let link = sourceBundle.appending(path: "EscapingLink")
    try FileManager.default.createSymbolicLink(
      at: link,
      withDestinationURL: FileManager.default.temporaryDirectory
    )
    let service = VirtualMachineCloneService(store: library)

    await #expect(throws: VirtualMachineCloneError.self) {
      _ = try await service.cloneVirtualMachine(id: source.id, name: "Rejected Copy")
    }
    #expect(FileManager.default.fileExists(atPath: link.path))
    #expect(try await library.list() == [source])
    try expectNoCloneStagingBundles(in: root)
  }

  @Test
  func recoveryRemovesInterruptedCloneStagingBundles() async throws {
    let root = temporaryRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

    let orphan = root.appending(
      path:
        "\(VirtualMachineLibrary.cloneStagingPrefix)orphan\(VirtualMachineLibrary.cloneStagingSuffix)",
      directoryHint: .isDirectory
    )
    try FileManager.default.createDirectory(at: orphan, withIntermediateDirectories: false)
    try Data("partial".utf8).write(to: orphan.appending(path: "partial.data"))

    let library = VirtualMachineLibrary(rootURL: root)
    let outcome = try await library.recoverInterruptedMacOSInstallations()

    #expect(outcome == .recovered)
    #expect(!FileManager.default.fileExists(atPath: orphan.path))
  }

  private func makeStoppedMachine(
    library: VirtualMachineLibrary,
    root: URL,
    name: String,
    microphoneEnabled: Bool = false
  ) async throws -> VirtualMachineManifest {
    let draft = try await library.createDraft(
      name: name,
      guest: .macOS,
      resources: try testResources()
    )
    let bundle = bundleURL(root: root, id: draft.id)
    let artifactDirectory = bundle.appending(
      path: MacPlatformArtifactURLs.directoryName,
      directoryHint: .isDirectory
    )
    try FileManager.default.createDirectory(
      at: artifactDirectory,
      withIntermediateDirectories: false
    )
    let artifacts = MacPlatformArtifactURLs(directory: artifactDirectory)
    try Data("auxiliary".utf8).write(to: artifacts.auxiliaryStorage)
    try Data("hardware".utf8).write(to: artifacts.hardwareModel)
    try Data("machine".utf8).write(to: artifacts.machineIdentifier)

    var stopped = draft
    stopped.installState = .stopped
    stopped.updatedAt = Date()
    stopped.auxiliaryStoragePath = MacPlatformArtifactURLs.auxiliaryStorageManifestPath
    stopped.hardwareModelPath = MacPlatformArtifactURLs.hardwareModelManifestPath
    stopped.machineIdentifierPath = MacPlatformArtifactURLs.machineIdentifierManifestPath
    if microphoneEnabled {
      stopped.audioConfiguration = MacVirtualMachineAudioConfiguration(
        revision: 1,
        isMicrophoneEnabled: true
      )
    }
    try write(stopped, to: bundle)
    return stopped
  }

  private func makeStoppedLinuxMachine(
    library: VirtualMachineLibrary,
    root: URL,
    name: String,
    networkAttachment: LinuxVirtualMachineNetworkAttachment? = nil
  ) async throws -> VirtualMachineManifest {
    let draft = try await library.createDraft(
      name: name,
      guest: .linux,
      resources: try testResources()
    )
    let bundle = bundleURL(root: root, id: draft.id)
    let artifactDirectory = bundle.appending(
      path: LinuxPlatformArtifactURLs.directoryName,
      directoryHint: .isDirectory
    )
    try FileManager.default.createDirectory(
      at: artifactDirectory,
      withIntermediateDirectories: false
    )
    let artifacts = LinuxPlatformArtifactURLs(directory: artifactDirectory)
    try Data("efi-state".utf8).write(to: artifacts.efiVariableStore)
    let identityGenerator = AppleLinuxVirtualMachineIdentityGenerator()
    try identityGenerator.makeIdentifierData().write(to: artifacts.machineIdentifier)

    var stopped = draft
    stopped.installState = .stopped
    stopped.updatedAt = Date()
    stopped.linuxConfiguration = LinuxVirtualMachineConfiguration(
      efiVariableStorePath: LinuxPlatformArtifactURLs.efiVariableStoreManifestPath,
      machineIdentifierPath: LinuxPlatformArtifactURLs.machineIdentifierManifestPath,
      installationMediaPath: nil,
      macAddress: identityGenerator.makeMACAddress(),
      sharesClipboard: true
    )
    if let networkAttachment {
      stopped.networkConfiguration = LinuxVirtualMachineNetworkConfiguration(
        attachment: networkAttachment
      )
    }
    try write(stopped, to: bundle)
    return stopped
  }

  private func testResources() throws -> VirtualMachineResources {
    try VirtualMachineResources(
      cpuCount: 4,
      memoryBytes: 4 * VirtualMachineResources.bytesPerGiB,
      diskBytes: 8 * VirtualMachineResources.bytesPerGiB
    )
  }

  private func temporaryRoot() -> URL {
    FileManager.default.temporaryDirectory
      .appending(path: UUID().uuidString, directoryHint: .isDirectory)
  }

  private func bundleURL(root: URL, id: UUID) -> URL {
    root
      .appending(path: id.uuidString.lowercased(), directoryHint: .isDirectory)
      .appendingPathExtension(VirtualMachineLibrary.bundleExtension)
  }

  private func write(_ manifest: VirtualMachineManifest, to bundleURL: URL) throws {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    try encoder.encode(manifest).write(
      to: bundleURL.appending(path: VirtualMachineLibrary.manifestFilename),
      options: .atomic
    )
  }

  private func expectNoCloneStagingBundles(in root: URL) throws {
    let entries = try FileManager.default.contentsOfDirectory(
      at: root,
      includingPropertiesForKeys: nil
    )
    #expect(
      entries.allSatisfy {
        !$0.lastPathComponent.hasPrefix(VirtualMachineLibrary.cloneStagingPrefix)
      }
    )
  }
}

private enum VirtualMachineCloneTestError: Error {
  case expected
}

private struct PartialFailingVirtualMachineBundleCopier: VirtualMachineBundleCopying {
  func copyBundle(for transaction: VirtualMachineCloneTransaction) async throws {
    try FileManager.default.createDirectory(
      at: transaction.stagingBundleURL,
      withIntermediateDirectories: false
    )
    try Data("partial".utf8).write(
      to: transaction.stagingBundleURL.appending(path: "partial.data")
    )
    throw VirtualMachineCloneTestError.expected
  }
}

private actor CancellableBlockingVirtualMachineBundleCopier: VirtualMachineBundleCopying {
  private var isStarted = false
  private var isCancelled = false
  private var startWaiters: [CheckedContinuation<Void, Never>] = []
  private var copyContinuation: CheckedContinuation<Void, Never>?

  func copyBundle(for transaction: VirtualMachineCloneTransaction) async throws {
    try FileManager.default.createDirectory(
      at: transaction.stagingBundleURL,
      withIntermediateDirectories: false
    )
    try Data("partial".utf8).write(
      to: transaction.stagingBundleURL.appending(path: "partial.data")
    )
    isStarted = true
    let waiters = startWaiters
    startWaiters.removeAll()
    for waiter in waiters {
      waiter.resume()
    }

    await withTaskCancellationHandler {
      await withCheckedContinuation { continuation in
        if isCancelled {
          continuation.resume()
        } else {
          copyContinuation = continuation
        }
      }
    } onCancel: {
      Task { await self.cancelCopy() }
    }
    try Task.checkCancellation()
  }

  func waitUntilStarted() async {
    guard !isStarted else { return }
    await withCheckedContinuation { continuation in
      startWaiters.append(continuation)
    }
  }

  private func cancelCopy() {
    isCancelled = true
    copyContinuation?.resume()
    copyContinuation = nil
  }
}
