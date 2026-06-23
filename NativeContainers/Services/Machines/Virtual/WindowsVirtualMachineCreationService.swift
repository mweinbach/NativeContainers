import Foundation

protocol WindowsVirtualMachineCreating: Sendable {
  func createWindowsVirtualMachine(
    name: String,
    resources: VirtualMachineResources,
    installationMediaURL: URL,
    securityMode: WindowsVirtualMachineSecurityMode
  ) async throws -> VirtualMachineManifest
}

struct WindowsVirtualMachineCreationService: WindowsVirtualMachineCreating {
  private let library: any VirtualMachineLibraryProtocol

  init(library: any VirtualMachineLibraryProtocol) {
    self.library = library
  }

  func createWindowsVirtualMachine(
    name: String,
    resources: VirtualMachineResources,
    installationMediaURL: URL,
    securityMode: WindowsVirtualMachineSecurityMode
  ) async throws -> VirtualMachineManifest {
    try Self.validate(resources)
    let draft = try await library.createDraft(
      name: name,
      guest: .windows,
      resources: resources
    )
    do {
      return try await library.prepareWindowsVM(
        id: draft.id,
        installationMediaURL: installationMediaURL,
        securityMode: securityMode
      )
    } catch {
      let preparationError = error
      do {
        try await library.discardVirtualMachine(id: draft.id)
      } catch {
        throw WindowsVirtualMachineCreationError.rollbackFailed(
          preparation: preparationError.localizedDescription,
          rollback: error.localizedDescription
        )
      }
      throw preparationError
    }
  }

  private static func validate(_ resources: VirtualMachineResources) throws {
    guard resources.cpuCount >= 2 else {
      throw WindowsVirtualMachineError.insufficientCPUCount(resources.cpuCount)
    }
    guard resources.memoryBytes >= 4 * VirtualMachineResources.bytesPerGiB else {
      throw WindowsVirtualMachineError.insufficientMemory(resources.memoryBytes)
    }
    guard resources.diskBytes >= 64 * VirtualMachineResources.bytesPerGiB else {
      throw WindowsVirtualMachineError.insufficientDisk(resources.diskBytes)
    }
  }
}

struct UnavailableWindowsVirtualMachineCreationService: WindowsVirtualMachineCreating {
  func createWindowsVirtualMachine(
    name: String,
    resources: VirtualMachineResources,
    installationMediaURL: URL,
    securityMode: WindowsVirtualMachineSecurityMode
  ) async throws -> VirtualMachineManifest {
    throw WindowsVirtualMachineCreationError.unavailable
  }
}

enum WindowsVirtualMachineCreationError: LocalizedError, Equatable, Sendable {
  case unavailable
  case rollbackFailed(preparation: String, rollback: String)

  var errorDescription: String? {
    switch self {
    case .unavailable:
      "Windows virtual machine creation is unavailable in this app configuration."
    case .rollbackFailed(let preparation, let rollback):
      "Windows virtual machine preparation failed: \(preparation) Cleanup also failed: \(rollback)"
    }
  }
}
