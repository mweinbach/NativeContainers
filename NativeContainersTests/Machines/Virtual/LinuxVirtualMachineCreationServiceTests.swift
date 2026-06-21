import Foundation
import Testing

@testable import NativeContainers

struct LinuxVirtualMachineCreationServiceTests {
  @Test
  func createsPreparedLinuxMachineThroughOneApplicationService() async throws {
    let library = LinuxCreationTestLibrary()
    let service = LinuxVirtualMachineCreationService(library: library)
    let resources = try makeLinuxCreationResources()
    let mediaURL = URL(filePath: "/tmp/Installer.iso")

    let machine = try await service.createLinuxVirtualMachine(
      name: "Desktop Linux",
      resources: resources,
      installationMediaURL: mediaURL
    )

    #expect(machine.guest == .linux)
    #expect(machine.installState == .readyToInstall)
    #expect(await library.preparedMediaURL == mediaURL)
    #expect(await library.discardCount == 0)
  }

  @Test
  func preparationFailureRollsBackDraft() async throws {
    let library = LinuxCreationTestLibrary(preparationError: .preparation)
    let service = LinuxVirtualMachineCreationService(library: library)

    await #expect(throws: LinuxCreationTestError.preparation) {
      _ = try await service.createLinuxVirtualMachine(
        name: "Rollback Linux",
        resources: try makeLinuxCreationResources(),
        installationMediaURL: URL(filePath: "/tmp/Installer.iso")
      )
    }

    #expect(await library.discardCount == 1)
    #expect(await library.manifests.isEmpty)
  }

  @Test
  func rollbackFailurePreservesBothFailureDescriptions() async throws {
    let library = LinuxCreationTestLibrary(
      preparationError: .preparation,
      discardError: .rollback
    )
    let service = LinuxVirtualMachineCreationService(library: library)

    do {
      _ = try await service.createLinuxVirtualMachine(
        name: "Rollback Failure",
        resources: try makeLinuxCreationResources(),
        installationMediaURL: URL(filePath: "/tmp/Installer.iso")
      )
      Issue.record("Expected creation to fail.")
    } catch let error as LinuxVirtualMachineCreationError {
      guard case .rollbackFailed(let preparation, let rollback) = error else {
        Issue.record("Expected rollbackFailed, received \(error).")
        return
      }
      #expect(preparation.contains("preparation"))
      #expect(rollback.contains("rollback"))
    }
  }
}

private actor LinuxCreationTestLibrary: VirtualMachineLibraryProtocol {
  private(set) var manifests: [VirtualMachineManifest] = []
  private(set) var preparedMediaURL: URL?
  private(set) var discardCount = 0
  private let preparationError: LinuxCreationTestError?
  private let discardError: LinuxCreationTestError?

  init(
    preparationError: LinuxCreationTestError? = nil,
    discardError: LinuxCreationTestError? = nil
  ) {
    self.preparationError = preparationError
    self.discardError = discardError
  }

  func list() -> [VirtualMachineManifest] {
    manifests
  }

  func createDraft(
    name: String,
    guest: VirtualMachineGuest,
    resources: VirtualMachineResources
  ) throws -> VirtualMachineManifest {
    let manifest = try VirtualMachineManifest(
      name: name,
      guest: guest,
      installState: .draft,
      resources: resources
    )
    manifests.append(manifest)
    return manifest
  }

  func prepareLinuxVM(
    id: UUID,
    installationMediaURL: URL
  ) throws -> VirtualMachineManifest {
    preparedMediaURL = installationMediaURL
    if let preparationError { throw preparationError }
    guard let index = manifests.firstIndex(where: { $0.id == id }) else {
      throw VirtualMachineModelError.virtualMachineNotFound(id)
    }
    var manifest = manifests[index]
    manifest.markReadyToInstallLinux(
      configuration: LinuxVirtualMachineConfiguration(
        efiVariableStorePath: "Linux/EFI",
        machineIdentifierPath: "Linux/MachineIdentifier",
        installationMediaPath: "Linux/Installer.iso",
        macAddress: "02:00:00:00:00:04"
      )
    )
    manifests[index] = manifest
    return manifest
  }

  func discardVirtualMachine(id: UUID) throws {
    discardCount += 1
    if let discardError { throw discardError }
    manifests.removeAll { $0.id == id }
  }
}

private enum LinuxCreationTestError: LocalizedError {
  case preparation
  case rollback

  var errorDescription: String? {
    switch self {
    case .preparation:
      "Expected preparation failure."
    case .rollback:
      "Expected rollback failure."
    }
  }
}

private func makeLinuxCreationResources() throws -> VirtualMachineResources {
  try VirtualMachineResources(
    cpuCount: 4,
    memoryBytes: 4 * VirtualMachineResources.bytesPerGiB,
    diskBytes: 32 * VirtualMachineResources.bytesPerGiB
  )
}
