import Foundation
import Testing

@testable import NativeContainers

@Suite("Virtual machine name services")
struct VirtualMachineNameServiceTests {
  @Test
  func macRenamePersistsUnderAReleasedRuntimeLease() async throws {
    let machine = try makeNameMacMachine()
    let recorder = NameReleaseRecorder()
    let leasing = NameMacLeaseStore(machine: machine, recorder: recorder)
    let persistence = NamePersistence(
      macName: machine.manifest.name,
      linuxName: "Linux"
    )
    let service = MacVirtualMachineNameService(
      leasingStore: leasing,
      persistence: persistence
    )

    let name = try await service.rename("  Renamed Mac  ", for: machine.manifest.id)

    #expect(name == "Renamed Mac")
    #expect(await persistence.macRenameCount == 1)
    #expect(await leasing.acquireCount == 1)
    #expect(recorder.count == 1)
  }

  @Test
  func linuxRenamePersistsUnderAReleasedRuntimeLease() async throws {
    let machine = try makeNameLinuxMachine()
    let recorder = NameReleaseRecorder()
    let leasing = NameLinuxLeaseStore(machine: machine, recorder: recorder)
    let persistence = NamePersistence(
      macName: "Mac",
      linuxName: machine.manifest.name
    )
    let service = LinuxVirtualMachineNameService(
      leasingStore: leasing,
      persistence: persistence
    )

    let name = try await service.rename(
      "Renamed Linux",
      for: machine.manifest.id
    )

    #expect(name == "Renamed Linux")
    #expect(await persistence.linuxRenameCount == 1)
    #expect(await leasing.acquireCount == 1)
    #expect(recorder.count == 1)
  }
}

private actor NamePersistence:
  MacVirtualMachineNamePersisting,
  LinuxVirtualMachineNamePersisting
{
  private var macName: String
  private var linuxName: String
  private(set) var macRenameCount = 0
  private(set) var linuxRenameCount = 0

  init(macName: String, linuxName: String) {
    self.macName = macName
    self.linuxName = linuxName
  }

  func macOSName(id: UUID) -> String {
    macName
  }

  func renameMacOS(
    to name: String,
    for lease: MacVirtualMachineRuntimeLease
  ) -> String {
    macRenameCount += 1
    macName = name.trimmingCharacters(in: .whitespacesAndNewlines)
    return macName
  }

  func linuxName(id: UUID) -> String {
    linuxName
  }

  func renameLinux(
    to name: String,
    for lease: LinuxVirtualMachineRuntimeLease
  ) -> String {
    linuxRenameCount += 1
    linuxName = name.trimmingCharacters(in: .whitespacesAndNewlines)
    return linuxName
  }
}

private actor NameMacLeaseStore: MacVirtualMachineRuntimeLeasing {
  let machine: ResolvedMacVirtualMachine
  let recorder: NameReleaseRecorder
  private(set) var acquireCount = 0

  init(machine: ResolvedMacVirtualMachine, recorder: NameReleaseRecorder) {
    self.machine = machine
    self.recorder = recorder
  }

  func acquireMacOSRuntime(id: UUID) -> MacVirtualMachineRuntimeLease {
    acquireCount += 1
    return MacVirtualMachineRuntimeLease(
      machine: machine,
      target: MacVirtualMachineRuntimeTarget(
        machineID: id,
        generation: UUID()
      )
    ) {
      self.recorder.record()
    }
  }
}

private actor NameLinuxLeaseStore: LinuxVirtualMachineRuntimeLeasing {
  let machine: ResolvedLinuxVirtualMachine
  let recorder: NameReleaseRecorder
  private(set) var acquireCount = 0

  init(machine: ResolvedLinuxVirtualMachine, recorder: NameReleaseRecorder) {
    self.machine = machine
    self.recorder = recorder
  }

  func acquireLinuxRuntime(id: UUID) -> LinuxVirtualMachineRuntimeLease {
    acquireCount += 1
    return LinuxVirtualMachineRuntimeLease(
      machine: machine,
      target: LinuxVirtualMachineRuntimeTarget(
        machineID: id,
        generation: UUID()
      )
    ) {
      self.recorder.record()
    }
  }
}

private final class NameReleaseRecorder: @unchecked Sendable {
  private let lock = NSLock()
  private var storedCount = 0

  var count: Int { lock.withLock { storedCount } }

  func record() {
    lock.withLock { storedCount += 1 }
  }
}

private func makeNameMacMachine() throws -> ResolvedMacVirtualMachine {
  let identifier = UUID()
  let manifest = try VirtualMachineManifest(
    id: identifier,
    name: "Mac",
    guest: .macOS,
    installState: .stopped,
    resources: nameResources()
  )
  let bundle = URL(filePath: "/tmp/\(identifier).nativevm")
  return ResolvedMacVirtualMachine(
    manifest: manifest,
    bundleURL: bundle,
    diskImageURL: bundle.appending(path: "Disk.img"),
    auxiliaryStorageURL: bundle.appending(path: "AuxiliaryStorage"),
    hardwareModelURL: bundle.appending(path: "HardwareModel"),
    machineIdentifierURL: bundle.appending(path: "MachineIdentifier")
  )
}

private func makeNameLinuxMachine() throws -> ResolvedLinuxVirtualMachine {
  let identifier = UUID()
  var manifest = try VirtualMachineManifest(
    id: identifier,
    name: "Linux",
    guest: .linux,
    installState: .stopped,
    resources: nameResources()
  )
  manifest.linuxConfiguration = LinuxVirtualMachineConfiguration(
    efiVariableStorePath: "Platform/EFI",
    machineIdentifierPath: "Platform/MachineIdentifier",
    installationMediaPath: nil,
    macAddress: "02:00:00:00:00:01"
  )
  let bundle = URL(filePath: "/tmp/\(identifier).nativevm")
  return ResolvedLinuxVirtualMachine(
    manifest: manifest,
    bundleURL: bundle,
    diskImageURL: bundle.appending(path: "Disk.img"),
    efiVariableStoreURL: bundle.appending(path: "Platform/EFI"),
    machineIdentifierURL: bundle.appending(path: "Platform/MachineIdentifier"),
    installationMediaURL: nil
  )
}

private func nameResources() throws -> VirtualMachineResources {
  try VirtualMachineResources(
    cpuCount: 4,
    memoryBytes: 8 * VirtualMachineResources.bytesPerGiB,
    diskBytes: 64 * VirtualMachineResources.bytesPerGiB
  )
}
