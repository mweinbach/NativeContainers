import Foundation
import Testing
@preconcurrency import Virtualization

@testable import NativeContainers

struct MacVirtualMachineSharedDirectoryStorageTests {
  @Test
  func privateSidecarRoundTripsDeterministically() throws {
    let root = try makeSharedDirectoryTestRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let store = FileMacVirtualMachineSharedDirectoryConfigurationStore()
    let firstID = try #require(UUID(uuidString: "00000000-0000-0000-0000-000000000001"))
    let secondID = try #require(UUID(uuidString: "00000000-0000-0000-0000-000000000002"))
    let configuration = MacVirtualMachineSharedDirectoryConfiguration(
      revision: 7,
      directories: [
        makeSharedDirectoryRecord(id: secondID, name: "Second", inode: 2),
        makeSharedDirectoryRecord(id: firstID, name: "First", inode: 1),
      ]
    )

    try store.save(configuration, to: root)
    let loaded = try store.load(from: root)
    let sidecar = root.appending(
      path: FileMacVirtualMachineSharedDirectoryConfigurationStore.filename
    )
    let attributes = try FileManager.default.attributesOfItem(atPath: sidecar.path)

    #expect(loaded == configuration)
    #expect(loaded.directories.map(\.id) == [firstID, secondID])
    #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)
    #expect(
      try FileManager.default.contentsOfDirectory(
        at: root,
        includingPropertiesForKeys: nil
      ).filter { $0.lastPathComponent.hasSuffix(".partial") }.isEmpty
    )
  }

  @Test
  func missingSidecarLoadsAsEmptyConfiguration() throws {
    let root = try makeSharedDirectoryTestRoot()
    defer { try? FileManager.default.removeItem(at: root) }

    let loaded = try FileMacVirtualMachineSharedDirectoryConfigurationStore().load(
      from: root
    )

    #expect(loaded == .empty)
  }

  @Test
  func permissiveSidecarIsRejected() throws {
    let root = try makeSharedDirectoryTestRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let store = FileMacVirtualMachineSharedDirectoryConfigurationStore()
    try store.save(
      MacVirtualMachineSharedDirectoryConfiguration(
        revision: 1,
        directories: [makeSharedDirectoryRecord()]
      ),
      to: root
    )
    let sidecar = root.appending(
      path: FileMacVirtualMachineSharedDirectoryConfigurationStore.filename
    )
    try FileManager.default.setAttributes(
      [.posixPermissions: 0o644],
      ofItemAtPath: sidecar.path
    )

    #expect(throws: MacVirtualMachineSharedDirectoryError.self) {
      _ = try store.load(from: root)
    }
  }

  @Test
  func emptyBookmarkAndHardLinkedSidecarAreRejected() throws {
    let emptyBookmarkRoot = try makeSharedDirectoryTestRoot()
    defer { try? FileManager.default.removeItem(at: emptyBookmarkRoot) }
    let hardLinkRoot = try makeSharedDirectoryTestRoot()
    defer { try? FileManager.default.removeItem(at: hardLinkRoot) }
    let store = FileMacVirtualMachineSharedDirectoryConfigurationStore()
    let emptyBookmark = MacVirtualMachineSharedDirectory(
      id: UUID(),
      guestName: "Empty",
      bookmarkData: Data(),
      lastKnownPath: "/tmp/Empty",
      sourceIdentity: .init(device: 1, inode: 1),
      readOnly: true
    )

    #expect(throws: MacVirtualMachineSharedDirectoryError.self) {
      try store.save(
        MacVirtualMachineSharedDirectoryConfiguration(
          revision: 1,
          directories: [emptyBookmark]
        ),
        to: emptyBookmarkRoot
      )
    }

    try store.save(
      MacVirtualMachineSharedDirectoryConfiguration(
        revision: 1,
        directories: [makeSharedDirectoryRecord()]
      ),
      to: hardLinkRoot
    )
    let sidecar = hardLinkRoot.appending(
      path: FileMacVirtualMachineSharedDirectoryConfigurationStore.filename
    )
    try FileManager.default.linkItem(
      at: sidecar,
      to: hardLinkRoot.appending(path: "SharedDirectories.backup")
    )
    #expect(throws: MacVirtualMachineSharedDirectoryError.self) {
      _ = try store.load(from: hardLinkRoot)
    }
  }

  @Test
  func bookmarkRoundTripRetainsDirectoryIdentityAndAccessMode() throws {
    let root = try makeSharedDirectoryTestRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let source = root.appending(path: "Source", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(
      at: source,
      withIntermediateDirectories: false
    )
    let service = MacVirtualMachineSharedDirectoryBookmarkService()
    let record = try service.makeRecord(
      request: MacVirtualMachineSharedDirectoryRequest(
        sourceURL: source,
        guestName: "Source",
        readOnly: true
      ),
      canonicalGuestName: "Source"
    )

    let access = try service.resolve([record])
    defer { access.release() }
    let resolved = try #require(access.directories.first)

    #expect(record.bookmarkData.isEmpty == false)
    #expect(record.lastKnownPath == source.path(percentEncoded: false))
    #expect(resolved.sourceURL.standardizedFileURL == source.standardizedFileURL)
    #expect(resolved.sourceIdentity == record.sourceIdentity)
    #expect(resolved.readOnly)
    access.release()
  }

  @Test
  func staleBookmarkAfterRenameFailsClosed() throws {
    let root = try makeSharedDirectoryTestRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let source = root.appending(path: "Before", directoryHint: .isDirectory)
    let renamed = root.appending(path: "After", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(
      at: source,
      withIntermediateDirectories: false
    )
    let service = MacVirtualMachineSharedDirectoryBookmarkService()
    let record = try service.makeRecord(
      request: MacVirtualMachineSharedDirectoryRequest(
        sourceURL: source,
        guestName: "Shared",
        readOnly: true
      ),
      canonicalGuestName: "Shared"
    )
    try FileManager.default.moveItem(at: source, to: renamed)

    #expect(
      throws: MacVirtualMachineSharedDirectoryError.staleBookmark("Shared")
    ) {
      _ = try service.resolve([record])
    }
  }

  @Test
  func symbolicDirectoryIsRejectedBeforeBookmarkCreation() throws {
    let root = try makeSharedDirectoryTestRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let source = root.appending(path: "Source", directoryHint: .isDirectory)
    let link = root.appending(path: "Link", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(
      at: source,
      withIntermediateDirectories: false
    )
    try FileManager.default.createSymbolicLink(
      at: link,
      withDestinationURL: source
    )

    #expect(throws: MacVirtualMachineSharedDirectoryError.self) {
      _ = try MacVirtualMachineSharedDirectoryBookmarkService().makeRecord(
        request: MacVirtualMachineSharedDirectoryRequest(
          sourceURL: link,
          guestName: "Link",
          readOnly: true
        ),
        canonicalGuestName: "Link"
      )
    }
  }

  #if arch(arm64)
    @Test @MainActor
    func deviceFactoryUsesOneAutomountDeviceForAllDirectories() throws {
      let root = try makeSharedDirectoryTestRoot()
      defer { try? FileManager.default.removeItem(at: root) }
      let first = root.appending(path: "First", directoryHint: .isDirectory)
      let second = root.appending(path: "Second", directoryHint: .isDirectory)
      try FileManager.default.createDirectory(at: first, withIntermediateDirectories: false)
      try FileManager.default.createDirectory(at: second, withIntermediateDirectories: false)
      let directories = [
        ResolvedMacVirtualMachineSharedDirectory(
          id: UUID(),
          guestName: "Projects",
          sourceURL: first,
          sourceIdentity: .init(device: 1, inode: 1),
          readOnly: false
        ),
        ResolvedMacVirtualMachineSharedDirectory(
          id: UUID(),
          guestName: "Reference",
          sourceURL: second,
          sourceIdentity: .init(device: 1, inode: 2),
          readOnly: true
        ),
      ]

      let optionalDevice = try AppleMacVirtualMachineSharedDirectoryDeviceFactory()
        .makeDevice(
          for: directories
        )
      let device = try #require(
        optionalDevice
      )
      let share = try #require(device.share as? VZMultipleDirectoryShare)

      #expect(
        device.tag == VZVirtioFileSystemDeviceConfiguration.macOSGuestAutomountTag
      )
      #expect(Set(share.directories.keys) == ["Projects", "Reference"])
      #expect(share.directories["Projects"]?.isReadOnly == false)
      #expect(share.directories["Reference"]?.isReadOnly == true)
    }
  #endif
}

@MainActor
struct MacVirtualMachineSharedDirectoryServiceTests {
  @Test
  func addCanonicalizesThenPersistsWhileHoldingStoppedLease() async throws {
    let fixture = try SharedDirectoryServiceFixture()

    let configuration = try await fixture.service.add(
      to: fixture.machine.manifest.id,
      request: MacVirtualMachineSharedDirectoryRequest(
        sourceURL: URL(filePath: "/tmp/Projects", directoryHint: .isDirectory),
        guestName: "  Projects  ",
        readOnly: false
      )
    )
    let persisted = await fixture.persistence.snapshot()

    #expect(configuration == persisted)
    #expect(configuration.revision == 1)
    #expect(configuration.directories.first?.guestName == "Projects")
    #expect(configuration.directories.first?.readOnly == false)
    #expect(fixture.savedState.inspectCount == 1)
    #expect(fixture.releaseRecorder.count == 1)
  }

  @Test
  func duplicateCanonicalNameIsRejectedBeforeLeaseAcquisition() async throws {
    let fixture = try SharedDirectoryServiceFixture(
      initialConfiguration: MacVirtualMachineSharedDirectoryConfiguration(
        revision: 1,
        directories: [makeSharedDirectoryRecord(name: "Projects")]
      )
    )

    await #expect(
      throws: MacVirtualMachineSharedDirectoryError.duplicateName("projects")
    ) {
      _ = try await fixture.service.add(
        to: fixture.machine.manifest.id,
        request: MacVirtualMachineSharedDirectoryRequest(
          sourceURL: URL(filePath: "/tmp/Other", directoryHint: .isDirectory),
          guestName: "projects",
          readOnly: true
        )
      )
    }

    #expect(fixture.releaseRecorder.count == 0)
  }

  @Test
  func savedStateBlocksMutationAndReleasesTemporaryLease() async throws {
    let fixture = try SharedDirectoryServiceFixture(
      savedStateStatus: .available(
        MacVirtualMachineSavedStateSummary(
          createdAt: Date(timeIntervalSince1970: 1),
          stateSizeBytes: 1
        )
      ))

    await #expect(
      throws: MacVirtualMachineSharedDirectoryError.savedStateBlocksChanges(
        fixture.machine.manifest.id
      )
    ) {
      _ = try await fixture.service.add(
        to: fixture.machine.manifest.id,
        request: MacVirtualMachineSharedDirectoryRequest(
          sourceURL: URL(filePath: "/tmp/Projects", directoryHint: .isDirectory),
          guestName: "Projects",
          readOnly: true
        )
      )
    }

    #expect(await fixture.persistence.snapshot() == .empty)
    #expect(fixture.releaseRecorder.count == 1)
  }

  @Test
  func removeAdvancesRevisionAndPreservesOtherShares() async throws {
    let removed = makeSharedDirectoryRecord(name: "Removed", inode: 1)
    let kept = makeSharedDirectoryRecord(name: "Kept", inode: 2)
    let fixture = try SharedDirectoryServiceFixture(
      initialConfiguration: MacVirtualMachineSharedDirectoryConfiguration(
        revision: 9,
        directories: [removed, kept]
      )
    )

    let configuration = try await fixture.service.remove(
      from: fixture.machine.manifest.id,
      sharedDirectoryID: removed.id
    )

    #expect(configuration.revision == 10)
    #expect(configuration.directories == [kept])
    #expect(fixture.releaseRecorder.count == 1)
  }
}

private func makeSharedDirectoryTestRoot() throws -> URL {
  let root = FileManager.default.temporaryDirectory.appending(
    path: "NativeContainers-SharedDirectoryTests-\(UUID().uuidString)",
    directoryHint: .isDirectory
  )
  try FileManager.default.createDirectory(
    at: root,
    withIntermediateDirectories: false
  )
  return root
}

private func makeSharedDirectoryRecord(
  id: UUID = UUID(),
  name: String = "Shared",
  inode: UInt64 = 1,
  readOnly: Bool = true
) -> MacVirtualMachineSharedDirectory {
  MacVirtualMachineSharedDirectory(
    id: id,
    guestName: name,
    bookmarkData: Data("bookmark-\(inode)".utf8),
    lastKnownPath: "/tmp/\(name)",
    sourceIdentity: MacVirtualMachineSharedDirectorySourceIdentity(
      device: 1,
      inode: inode
    ),
    readOnly: readOnly
  )
}

@MainActor
private struct SharedDirectoryServiceFixture {
  let machine: ResolvedMacVirtualMachine
  let persistence: SharedDirectoryPersistence
  let savedState: SharedDirectorySavedStateService
  let releaseRecorder = SharedDirectoryReleaseRecorder()
  let service: MacVirtualMachineSharedDirectoryService

  init(
    initialConfiguration: MacVirtualMachineSharedDirectoryConfiguration = .empty,
    savedStateStatus: MacVirtualMachineSavedStateStatus = .none
  ) throws {
    machine = try makeSharedDirectoryMachine()
    persistence = SharedDirectoryPersistence(initial: initialConfiguration)
    savedState = SharedDirectorySavedStateService(status: savedStateStatus)
    let store = SharedDirectoryLeaseStore(
      machine: machine,
      releaseRecorder: releaseRecorder
    )
    service = MacVirtualMachineSharedDirectoryService(
      leasingStore: store,
      persistence: persistence,
      savedStateService: savedState,
      bookmarkService: SharedDirectoryBookmarker(),
      nameValidator: SharedDirectoryNameValidator()
    )
  }
}

private struct SharedDirectoryNameValidator:
  MacVirtualMachineSharedDirectoryNameValidating
{
  func canonicalName(from proposedName: String) throws -> String {
    proposedName.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  func validatePersistedName(_ name: String) throws {}
}

private struct SharedDirectoryBookmarker:
  MacVirtualMachineSharedDirectoryBookmarking
{
  func makeRecord(
    request: MacVirtualMachineSharedDirectoryRequest,
    canonicalGuestName: String
  ) -> MacVirtualMachineSharedDirectory {
    makeSharedDirectoryRecord(
      name: canonicalGuestName,
      inode: request.readOnly ? 1 : 2,
      readOnly: request.readOnly
    )
  }

  func resolve(
    _ directories: [MacVirtualMachineSharedDirectory]
  ) -> MacVirtualMachineSharedDirectoryAccess {
    MacVirtualMachineSharedDirectoryAccess(directories: [], accessedURLs: [])
  }
}

private actor SharedDirectoryPersistence:
  MacVirtualMachineSharedDirectoryPersisting
{
  private var configuration: MacVirtualMachineSharedDirectoryConfiguration

  init(initial: MacVirtualMachineSharedDirectoryConfiguration) {
    configuration = initial
  }

  func snapshot() -> MacVirtualMachineSharedDirectoryConfiguration {
    configuration
  }

  func macOSSharedDirectoryConfiguration(
    id: UUID
  ) -> MacVirtualMachineSharedDirectoryConfiguration {
    configuration
  }

  func addMacOSSharedDirectory(
    _ directory: MacVirtualMachineSharedDirectory,
    for lease: MacVirtualMachineRuntimeLease
  ) throws -> MacVirtualMachineSharedDirectoryConfiguration {
    guard configuration.revision < UInt64.max else {
      throw MacVirtualMachineSharedDirectoryError.configurationRevisionOverflow
    }
    configuration = MacVirtualMachineSharedDirectoryConfiguration(
      revision: configuration.revision + 1,
      directories: configuration.directories + [directory]
    )
    return configuration
  }

  func removeMacOSSharedDirectory(
    id: UUID,
    for lease: MacVirtualMachineRuntimeLease
  ) throws -> MacVirtualMachineSharedDirectoryConfiguration {
    guard configuration.directories.contains(where: { $0.id == id }) else {
      throw MacVirtualMachineSharedDirectoryError.sharedDirectoryNotFound(id)
    }
    configuration = MacVirtualMachineSharedDirectoryConfiguration(
      revision: configuration.revision + 1,
      directories: configuration.directories.filter { $0.id != id }
    )
    return configuration
  }
}

private actor SharedDirectoryLeaseStore: MacVirtualMachineRuntimeLeasing {
  let machine: ResolvedMacVirtualMachine
  let releaseRecorder: SharedDirectoryReleaseRecorder

  init(
    machine: ResolvedMacVirtualMachine,
    releaseRecorder: SharedDirectoryReleaseRecorder
  ) {
    self.machine = machine
    self.releaseRecorder = releaseRecorder
  }

  func acquireMacOSRuntime(id: UUID) -> MacVirtualMachineRuntimeLease {
    MacVirtualMachineRuntimeLease(
      machine: machine,
      target: MacVirtualMachineRuntimeTarget(
        machineID: id,
        generation: UUID()
      )
    ) {
      self.releaseRecorder.record()
    }
  }
}

private final class SharedDirectoryReleaseRecorder: @unchecked Sendable {
  private let lock = NSLock()
  private var storedCount = 0

  var count: Int { lock.withLock { storedCount } }

  func record() {
    lock.withLock { storedCount += 1 }
  }
}

@MainActor
private final class SharedDirectorySavedStateService:
  MacVirtualMachineSavedStateManaging
{
  let status: MacVirtualMachineSavedStateStatus
  private(set) var inspectCount = 0

  init(status: MacVirtualMachineSavedStateStatus) {
    self.status = status
  }

  func inspect(
    for lease: MacVirtualMachineRuntimeLease
  ) -> MacVirtualMachineSavedStateStatus {
    inspectCount += 1
    return status
  }

  func saveCheckpoint(
    session: any MacVirtualMachineRuntimeEngineSession,
    lease: MacVirtualMachineRuntimeLease
  ) async throws -> MacVirtualMachineSavedStateSummary {
    throw MacVirtualMachineRuntimeError.operationUnavailable("save")
  }

  func restoreCheckpoint(
    session: any MacVirtualMachineRuntimeEngineSession,
    lease: MacVirtualMachineRuntimeLease
  ) async throws -> MacVirtualMachineSavedStateSummary {
    throw MacVirtualMachineRuntimeError.operationUnavailable("restore")
  }

  func discardCheckpoint(for lease: MacVirtualMachineRuntimeLease) async throws {
    throw MacVirtualMachineRuntimeError.operationUnavailable("discard")
  }
}

private func makeSharedDirectoryMachine() throws -> ResolvedMacVirtualMachine {
  let identifier = UUID()
  let resources = try VirtualMachineResources(
    cpuCount: 4,
    memoryBytes: 8 * VirtualMachineResources.bytesPerGiB,
    diskBytes: 64 * VirtualMachineResources.bytesPerGiB
  )
  let manifest = try VirtualMachineManifest(
    id: identifier,
    name: "Shared Directory Service",
    guest: .macOS,
    installState: .stopped,
    resources: resources
  )
  let bundle = URL(
    filePath: "/tmp/\(identifier.uuidString).nativevm",
    directoryHint: .isDirectory
  )
  return ResolvedMacVirtualMachine(
    manifest: manifest,
    bundleURL: bundle,
    diskImageURL: bundle.appending(path: "Disk.img"),
    auxiliaryStorageURL: bundle.appending(path: "AuxiliaryStorage"),
    hardwareModelURL: bundle.appending(path: "HardwareModel"),
    machineIdentifierURL: bundle.appending(path: "MachineIdentifier")
  )
}
