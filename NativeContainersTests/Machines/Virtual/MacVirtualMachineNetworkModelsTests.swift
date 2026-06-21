import Foundation
import Testing

@testable import NativeContainers

@Suite("Mac virtual machine network models")
struct MacVirtualMachineNetworkModelsTests {
  @Test
  func configurationRevisionChangesOnlyWithTheAttachment() throws {
    let initial = MacVirtualMachineNetworkConfiguration.nat
    let unchanged = try initial.settingAttachment(.nat)
    let shared = try initial.settingAttachment(.shared)
    let hostOnly = try shared.settingAttachment(.hostOnly)

    #expect(unchanged == initial)
    #expect(shared.revision == 1)
    #expect(shared.attachment == .shared)
    #expect(hostOnly.revision == 2)
    #expect(hostOnly.attachment == .hostOnly)
    #expect(!MacVirtualMachineNetworkAttachment.nat.usesCustomVmnetNetwork)
    #expect(MacVirtualMachineNetworkAttachment.shared.usesCustomVmnetNetwork)
    #expect(MacVirtualMachineNetworkAttachment.hostOnly.usesCustomVmnetNetwork)

    #expect(
      throws: MacVirtualMachineNetworkError.configurationRevisionOverflow
    ) {
      _ = try MacVirtualMachineNetworkConfiguration(
        revision: .max,
        attachment: .nat
      ).settingAttachment(.shared)
    }
  }

  @Test
  func sameHostClonePreservesModeWhilePortableExportReturnsToNAT() throws {
    var source = try makeNetworkManifest()
    source.networkConfiguration = MacVirtualMachineNetworkConfiguration(
      revision: 3,
      attachment: .hostOnly
    )

    let clone = try VirtualMachineManifest(cloning: source, name: "Network Clone")
    let portable = source.portableRepresentation()

    #expect(clone.networkConfiguration == source.networkConfiguration)
    #expect(clone.effectiveNetworkConfiguration.attachment == .hostOnly)
    #expect(portable.networkConfiguration == nil)
    #expect(portable.effectiveNetworkConfiguration == .nat)
  }

  @Test
  func descriptorTracksModeAndRevisionForSavedStateCompatibility() throws {
    let service = MacVirtualMachineConfigurationDescriptorService()

    let nat = try service.descriptor(
      for: makeResolvedNetworkMachine(attachment: .nat, revision: 0)
    )
    let shared = try service.descriptor(
      for: makeResolvedNetworkMachine(attachment: .shared, revision: 2)
    )
    let hostOnly = try service.descriptor(
      for: makeResolvedNetworkMachine(attachment: .hostOnly, revision: 4)
    )

    #expect(nat.networkAttachment == "NAT")
    #expect(nat.networkConfigurationRevision == nil)
    #expect(shared.networkAttachment == "VmnetShared")
    #expect(shared.networkConfigurationRevision == 2)
    #expect(hostOnly.networkAttachment == "VmnetHostOnly")
    #expect(hostOnly.networkConfigurationRevision == 4)
  }
}

private func makeNetworkManifest(
  id: UUID = UUID()
) throws -> VirtualMachineManifest {
  try VirtualMachineManifest(
    id: id,
    name: "Network VM",
    guest: .macOS,
    installState: .stopped,
    resources: VirtualMachineResources(
      cpuCount: 4,
      memoryBytes: 8 * VirtualMachineResources.bytesPerGiB,
      diskBytes: 64 * VirtualMachineResources.bytesPerGiB
    )
  )
}

private func makeResolvedNetworkMachine(
  attachment: MacVirtualMachineNetworkAttachment,
  revision: UInt64
) throws -> ResolvedMacVirtualMachine {
  var manifest = try makeNetworkManifest()
  manifest.auxiliaryStoragePath = "AuxiliaryStorage"
  manifest.networkConfiguration = MacVirtualMachineNetworkConfiguration(
    revision: revision,
    attachment: attachment
  )
  let bundle = URL(
    filePath: "/tmp/\(manifest.id.uuidString).nativevm",
    directoryHint: .isDirectory
  )
  return ResolvedMacVirtualMachine(
    manifest: manifest,
    bundleURL: bundle,
    diskImageURL: bundle.appending(path: manifest.diskImagePath),
    auxiliaryStorageURL: bundle.appending(path: "AuxiliaryStorage"),
    hardwareModelURL: bundle.appending(path: "HardwareModel"),
    machineIdentifierURL: bundle.appending(path: "MachineIdentifier")
  )
}
