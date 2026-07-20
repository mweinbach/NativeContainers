import Foundation
import Testing

@testable import NativeContainers

@Suite(.serialized)
struct LinuxBoxManifestContractTests {
  @Test
  func legacyManifestRoundTripsWithoutSchemaMutation() throws {
    let root = temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let store = VirtualMachineBundleStore(rootURL: root, fileManager: .default)
    try store.ensureRootExists()
    var manifest = try makeManifest(schemaVersion: 1)
    manifest.linuxConfiguration = makeLinuxConfiguration(descriptor: nil)
    let bundle = store.bundleURL(for: manifest.id)
    try FileManager.default.createDirectory(at: bundle, withIntermediateDirectories: false)

    try store.write(manifest, to: store.manifestURL(for: manifest.id))
    var loaded = try store.readManifest(in: bundle)
    _ = try loaded.rename(to: "Legacy Renamed")
    try store.write(loaded, to: store.manifestURL(for: loaded.id))
    let rewritten = try store.readManifest(in: bundle)

    #expect(rewritten.schemaVersion == 1)
    #expect(rewritten.linuxConfiguration?.linuxBoxDescriptor == nil)
    #expect(rewritten.name == "Legacy Renamed")
  }

  @Test
  func newAndClonedManifestsUseSchemaTwo() throws {
    let fresh = try makeManifest()
    var legacy = try makeManifest(schemaVersion: 1)
    legacy.linuxConfiguration = makeLinuxConfiguration(descriptor: nil)
    let clone = try VirtualMachineManifest(
      cloning: legacy,
      name: "Legacy Clone",
      linuxMACAddress: "02:00:00:00:00:02"
    )

    #expect(fresh.schemaVersion == 2)
    #expect(clone.schemaVersion == 2)
    #expect(clone.id != legacy.id)
  }

  @Test
  func managedClonePreservesImageIdentityAndRefreshesMachineIdentity() throws {
    var source = try makeManifest()
    source.linuxConfiguration = makeLinuxConfiguration(descriptor: try makeDescriptor())

    let clone = try VirtualMachineManifest(
      cloning: source,
      name: "Managed Clone",
      linuxMACAddress: "02:00:00:00:00:03"
    )

    #expect(source.isManagedLinuxBox)
    #expect(clone.isManagedLinuxBox)
    #expect(clone.id != source.id)
    #expect(clone.linuxConfiguration?.macAddress != source.linuxConfiguration?.macAddress)
    #expect(
      clone.linuxConfiguration?.linuxBoxDescriptor
        == source.linuxConfiguration?.linuxBoxDescriptor
    )
  }

  @Test
  func profileRoundTripsAndDefaultsToStandard() throws {
    let standard = try makeDescriptor()
    #expect(standard.profile == .standard)
    let residential = try LinuxBoxDescriptor(
      imageID: standard.imageID,
      imageBuildRevision: standard.imageBuildRevision,
      rawImageSHA512: standard.rawImageSHA512,
      profile: .residential
    )
    let data = try JSONEncoder().encode(residential)
    let decoded = try JSONDecoder().decode(LinuxBoxDescriptor.self, from: data)
    #expect(decoded == residential)
    #expect(decoded.profile == .residential)
  }

  @Test
  func hardenedDetectionMatchesResidentialManagedBoxes() throws {
    var standard = try makeManifest()
    standard.linuxConfiguration = makeLinuxConfiguration(descriptor: try makeDescriptor())
    #expect(standard.isManagedLinuxBox)
    #expect(!standard.isHardenedLinuxBox)

    var residential = try makeManifest()
    residential.linuxConfiguration = makeLinuxConfiguration(
      descriptor: try LinuxBoxDescriptor(
        imageID: "nativecontainers-debian-13-arm64-v1",
        imageBuildRevision: "20260718.1",
        rawImageSHA512: String(repeating: "a", count: 128),
        profile: .residential
      )
    )
    #expect(residential.isManagedLinuxBox)
    #expect(residential.isHardenedLinuxBox)
  }

  @Test
  func invalidSchemaDescriptorCombinationsAreRejected() throws {
    var legacy = try makeManifest(schemaVersion: 1)
    legacy.linuxConfiguration = makeLinuxConfiguration(descriptor: try makeDescriptor())
    #expect(throws: VirtualMachineModelError.self) {
      try legacy.validateSchema()
    }

    #expect(throws: VirtualMachineModelError.unsupportedSchema(3)) {
      _ = try makeManifest(schemaVersion: 3)
    }
  }

  @Test
  func managedTransferIsRejectedBeforeBundlePreparation() async throws {
    let root = temporaryDirectory()
    let externalRoot = temporaryDirectory()
    defer {
      try? FileManager.default.removeItem(at: root)
      try? FileManager.default.removeItem(at: externalRoot)
    }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: externalRoot, withIntermediateDirectories: true)
    let library = VirtualMachineLibrary(rootURL: root)
    let store = VirtualMachineBundleStore(rootURL: root, fileManager: .default)
    var standard = try makeManifest()
    standard.linuxConfiguration = makeLinuxConfiguration(
      descriptor: try makeDescriptor(profile: .standard)
    )
    let standardBundle = store.bundleURL(for: standard.id)
    try FileManager.default.createDirectory(at: standardBundle, withIntermediateDirectories: false)
    let platformDirectory = standardBundle.appending(
      path: "Platform",
      directoryHint: .isDirectory
    )
    try FileManager.default.createDirectory(
      at: platformDirectory,
      withIntermediateDirectories: false
    )
    try Data(repeating: 0xA5, count: 4 * 1024).write(
      to: standardBundle.appending(path: standard.diskImagePath)
    )
    try Data("efi-test".utf8).write(
      to: standardBundle.appending(path: standard.linuxConfiguration!.efiVariableStorePath)
    )
    try Data("machine-id-test".utf8).write(
      to: standardBundle.appending(path: standard.linuxConfiguration!.machineIdentifierPath)
    )
    try store.write(standard, to: store.manifestURL(for: standard.id))
    let standardLease = try await library.acquireExportSource(id: standard.id)
    #expect(standardLease.manifest.linuxConfiguration?.linuxBoxDescriptor?.profile == .standard)
    standardLease.release()

    var manifest = try makeManifest()
    manifest.linuxConfiguration = makeLinuxConfiguration(
      descriptor: try makeDescriptor(profile: .residential)
    )
    let localBundle = store.bundleURL(for: manifest.id)
    try FileManager.default.createDirectory(at: localBundle, withIntermediateDirectories: false)
    try store.write(manifest, to: store.manifestURL(for: manifest.id))

    await #expect(throws: VirtualMachineTransferError.managedLinuxBoxUnsupported) {
      _ = try await library.acquireExportSource(id: manifest.id)
    }

    let externalBundle = externalRoot.appending(path: "Managed.nativevm", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: externalBundle, withIntermediateDirectories: false)
    try store.write(
      manifest,
      to: externalBundle.appending(path: VirtualMachineLibrary.manifestFilename)
    )
    await #expect(throws: VirtualMachineTransferError.managedLinuxBoxUnsupported) {
      _ = try await library.beginImport(from: externalBundle, mode: .preserveIdentity)
    }
  }

  @Test
  func managedTransferErrorDescriptionNamesResidentialProfile() {
    #expect(
      VirtualMachineTransferError.managedLinuxBoxUnsupported.errorDescription
        == "Residential Linux boxes cannot be imported or exported."
    )
  }

  private func makeManifest(schemaVersion: Int = 2) throws -> VirtualMachineManifest {
    try VirtualMachineManifest(
      schemaVersion: schemaVersion,
      name: "Linux Box",
      guest: .linux,
      installState: .stopped,
      resources: VirtualMachineResources(
        cpuCount: 4,
        memoryBytes: 8 * VirtualMachineResources.bytesPerGiB,
        diskBytes: 32 * VirtualMachineResources.bytesPerGiB
      )
    )
  }

  private func makeLinuxConfiguration(
    descriptor: LinuxBoxDescriptor?
  ) -> LinuxVirtualMachineConfiguration {
    LinuxVirtualMachineConfiguration(
      efiVariableStorePath: "Platform/EFI.nvram",
      machineIdentifierPath: "Platform/MachineIdentifier.bin",
      installationMediaPath: nil,
      macAddress: "02:00:00:00:00:01",
      sharesClipboard: descriptor == nil,
      linuxBoxDescriptor: descriptor
    )
  }

  private func makeDescriptor(profile: LinuxBoxProfile = .standard) throws -> LinuxBoxDescriptor {
    try LinuxBoxDescriptor(
      imageID: "nativecontainers-debian-13-arm64-v1",
      imageBuildRevision: "20260718.1",
      rawImageSHA512: String(repeating: "a", count: 128),
      profile: profile
    )
  }

  private func temporaryDirectory() -> URL {
    FileManager.default.temporaryDirectory.appending(
      path: "LinuxBoxManifestContractTests-\(UUID().uuidString)",
      directoryHint: .isDirectory
    )
  }
}
