import Foundation
import Testing
@preconcurrency import Virtualization

@testable import NativeContainers

@MainActor
struct LinuxVirtualMachineSharedDirectoryServiceTests {
  @Test
  func addCanonicalizesAndPersistsWithStoppedLease() async throws {
    let fixture = try LinuxSharedDirectoryServiceFixture()

    let configuration = try await fixture.service.add(
      to: fixture.machine.manifest.id,
      request: LinuxVirtualMachineSharedDirectoryRequest(
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
    #expect(fixture.releaseRecorder.count == 1)
  }

  @Test
  func duplicateNameIsRejectedBeforeLeaseAcquisition() async throws {
    let fixture = try LinuxSharedDirectoryServiceFixture(
      initialConfiguration: LinuxVirtualMachineSharedDirectoryConfiguration(
        revision: 1,
        directories: [makeLinuxSharedDirectoryRecord(name: "Projects")]
      )
    )

    await #expect(
      throws: LinuxVirtualMachineSharedDirectoryError.duplicateName("projects")
    ) {
      _ = try await fixture.service.add(
        to: fixture.machine.manifest.id,
        request: LinuxVirtualMachineSharedDirectoryRequest(
          sourceURL: URL(filePath: "/tmp/Other", directoryHint: .isDirectory),
          guestName: "projects",
          readOnly: true
        )
      )
    }

    #expect(fixture.releaseRecorder.count == 0)
  }

  @Test
  func removeAdvancesRevisionAndPreservesOtherShares() async throws {
    let removed = makeLinuxSharedDirectoryRecord(name: "Removed", inode: 1)
    let kept = makeLinuxSharedDirectoryRecord(name: "Kept", inode: 2)
    let fixture = try LinuxSharedDirectoryServiceFixture(
      initialConfiguration: LinuxVirtualMachineSharedDirectoryConfiguration(
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

  @Test
  func linuxDeviceUsesStableMountTagForAllDirectories() throws {
    let directories = [
      ResolvedLinuxVirtualMachineSharedDirectory(
        id: UUID(),
        guestName: "Projects",
        sourceURL: URL(filePath: "/tmp/Projects", directoryHint: .isDirectory),
        sourceIdentity: .init(device: 1, inode: 1),
        readOnly: false
      ),
      ResolvedLinuxVirtualMachineSharedDirectory(
        id: UUID(),
        guestName: "Reference",
        sourceURL: URL(filePath: "/tmp/Reference", directoryHint: .isDirectory),
        sourceIdentity: .init(device: 1, inode: 2),
        readOnly: true
      ),
    ]

    let device = try #require(
      try AppleLinuxVirtualMachineSharedDirectoryDeviceFactory().makeDevice(
        for: directories
      )
    )
    let share = try #require(device.share as? VZMultipleDirectoryShare)

    #expect(
      device.tag == AppleLinuxVirtualMachineSharedDirectoryDeviceFactory.mountTag
    )
    #expect(Set(share.directories.keys) == ["Projects", "Reference"])
    #expect(share.directories["Projects"]?.isReadOnly == false)
    #expect(share.directories["Reference"]?.isReadOnly == true)
  }
}

@MainActor
private struct LinuxSharedDirectoryServiceFixture {
  let machine: ResolvedLinuxVirtualMachine
  let persistence: LinuxSharedDirectoryPersistence
  let releaseRecorder = LinuxSharedDirectoryReleaseRecorder()
  let service: LinuxVirtualMachineSharedDirectoryService

  init(
    initialConfiguration: LinuxVirtualMachineSharedDirectoryConfiguration = .empty
  ) throws {
    machine = try makeLinuxSharedDirectoryMachine()
    persistence = LinuxSharedDirectoryPersistence(initial: initialConfiguration)
    let store = LinuxSharedDirectoryLeaseStore(
      machine: machine,
      releaseRecorder: releaseRecorder
    )
    service = LinuxVirtualMachineSharedDirectoryService(
      leasingStore: store,
      persistence: persistence,
      bookmarkService: LinuxSharedDirectoryBookmarker(),
      nameValidator: LinuxSharedDirectoryNameValidator()
    )
  }
}

private struct LinuxSharedDirectoryNameValidator:
  LinuxVirtualMachineSharedDirectoryNameValidating
{
  func canonicalName(from proposedName: String) -> String {
    proposedName.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  func validatePersistedName(_ name: String) throws {}
}

private struct LinuxSharedDirectoryBookmarker:
  LinuxVirtualMachineSharedDirectoryBookmarking
{
  func makeRecord(
    request: LinuxVirtualMachineSharedDirectoryRequest,
    canonicalGuestName: String
  ) -> LinuxVirtualMachineSharedDirectory {
    makeLinuxSharedDirectoryRecord(
      name: canonicalGuestName,
      inode: request.readOnly ? 1 : 2,
      readOnly: request.readOnly
    )
  }

  func resolve(
    _ directories: [LinuxVirtualMachineSharedDirectory]
  ) -> LinuxVirtualMachineSharedDirectoryAccess {
    LinuxVirtualMachineSharedDirectoryAccess(directories: [], accessedURLs: [])
  }
}

private actor LinuxSharedDirectoryPersistence:
  LinuxVirtualMachineSharedDirectoryPersisting
{
  private var configuration: LinuxVirtualMachineSharedDirectoryConfiguration

  init(initial: LinuxVirtualMachineSharedDirectoryConfiguration) {
    configuration = initial
  }

  func snapshot() -> LinuxVirtualMachineSharedDirectoryConfiguration {
    configuration
  }

  func linuxSharedDirectoryConfiguration(
    id: UUID
  ) -> LinuxVirtualMachineSharedDirectoryConfiguration {
    configuration
  }

  func addLinuxSharedDirectory(
    _ directory: LinuxVirtualMachineSharedDirectory,
    for lease: LinuxVirtualMachineRuntimeLease
  ) throws -> LinuxVirtualMachineSharedDirectoryConfiguration {
    guard configuration.revision < UInt64.max else {
      throw LinuxVirtualMachineSharedDirectoryError.configurationRevisionOverflow
    }
    configuration = LinuxVirtualMachineSharedDirectoryConfiguration(
      revision: configuration.revision + 1,
      directories: configuration.directories + [directory]
    )
    return configuration
  }

  func removeLinuxSharedDirectory(
    id: UUID,
    for lease: LinuxVirtualMachineRuntimeLease
  ) throws -> LinuxVirtualMachineSharedDirectoryConfiguration {
    guard configuration.directories.contains(where: { $0.id == id }) else {
      throw LinuxVirtualMachineSharedDirectoryError.sharedDirectoryNotFound(id)
    }
    configuration = LinuxVirtualMachineSharedDirectoryConfiguration(
      revision: configuration.revision + 1,
      directories: configuration.directories.filter { $0.id != id }
    )
    return configuration
  }
}

private actor LinuxSharedDirectoryLeaseStore: LinuxVirtualMachineRuntimeLeasing {
  let machine: ResolvedLinuxVirtualMachine
  let releaseRecorder: LinuxSharedDirectoryReleaseRecorder

  init(
    machine: ResolvedLinuxVirtualMachine,
    releaseRecorder: LinuxSharedDirectoryReleaseRecorder
  ) {
    self.machine = machine
    self.releaseRecorder = releaseRecorder
  }

  func acquireLinuxRuntime(id: UUID) -> LinuxVirtualMachineRuntimeLease {
    LinuxVirtualMachineRuntimeLease(
      machine: machine,
      target: LinuxVirtualMachineRuntimeTarget(
        machineID: id,
        generation: UUID()
      )
    ) {
      self.releaseRecorder.record()
    }
  }
}

private final class LinuxSharedDirectoryReleaseRecorder: @unchecked Sendable {
  private let lock = NSLock()
  private var storedCount = 0

  var count: Int { lock.withLock { storedCount } }

  func record() {
    lock.withLock { storedCount += 1 }
  }
}

private func makeLinuxSharedDirectoryRecord(
  id: UUID = UUID(),
  name: String = "Shared",
  inode: UInt64 = 1,
  readOnly: Bool = true
) -> LinuxVirtualMachineSharedDirectory {
  LinuxVirtualMachineSharedDirectory(
    id: id,
    guestName: name,
    bookmarkData: Data("bookmark-\(inode)".utf8),
    lastKnownPath: "/tmp/\(name)",
    sourceIdentity: LinuxVirtualMachineSharedDirectorySourceIdentity(
      device: 1,
      inode: inode
    ),
    readOnly: readOnly
  )
}

private func makeLinuxSharedDirectoryMachine() throws -> ResolvedLinuxVirtualMachine {
  let identifier = UUID()
  let resources = try VirtualMachineResources(
    cpuCount: 4,
    memoryBytes: 4 * VirtualMachineResources.bytesPerGiB,
    diskBytes: 32 * VirtualMachineResources.bytesPerGiB
  )
  var manifest = try VirtualMachineManifest(
    id: identifier,
    name: "Linux Shared Directory Service",
    guest: .linux,
    installState: .stopped,
    resources: resources
  )
  manifest.linuxConfiguration = LinuxVirtualMachineConfiguration(
    efiVariableStorePath: "Platform/EFI",
    machineIdentifierPath: "Platform/MachineIdentifier",
    installationMediaPath: nil,
    macAddress: "02:00:00:00:00:01"
  )
  let bundle = URL(
    filePath: "/tmp/\(identifier.uuidString).nativevm",
    directoryHint: .isDirectory
  )
  return ResolvedLinuxVirtualMachine(
    manifest: manifest,
    bundleURL: bundle,
    diskImageURL: bundle.appending(path: "Disk.img"),
    efiVariableStoreURL: bundle.appending(path: "Platform/EFI"),
    machineIdentifierURL: bundle.appending(path: "Platform/MachineIdentifier"),
    installationMediaURL: nil
  )
}
