import Foundation

protocol LinuxVirtualMachineCreating: Sendable {
  func createLinuxVirtualMachine(
    name: String,
    resources: VirtualMachineResources,
    installationMediaURL: URL
  ) async throws -> VirtualMachineManifest
}

struct LinuxVirtualMachineCreationService: LinuxVirtualMachineCreating {
  private let library: any VirtualMachineLibraryProtocol

  init(library: any VirtualMachineLibraryProtocol) {
    self.library = library
  }

  func createLinuxVirtualMachine(
    name: String,
    resources: VirtualMachineResources,
    installationMediaURL: URL
  ) async throws -> VirtualMachineManifest {
    let draft = try await library.createDraft(
      name: name,
      guest: .linux,
      resources: resources
    )
    do {
      return try await library.prepareLinuxVM(
        id: draft.id,
        installationMediaURL: installationMediaURL
      )
    } catch {
      let preparationError = error
      do {
        try await library.discardVirtualMachine(id: draft.id)
      } catch {
        throw LinuxVirtualMachineCreationError.rollbackFailed(
          preparation: preparationError.localizedDescription,
          rollback: error.localizedDescription
        )
      }
      throw preparationError
    }
  }
}

struct UnavailableLinuxVirtualMachineCreationService: LinuxVirtualMachineCreating {
  func createLinuxVirtualMachine(
    name: String,
    resources: VirtualMachineResources,
    installationMediaURL: URL
  ) async throws -> VirtualMachineManifest {
    throw LinuxVirtualMachineCreationError.unavailable
  }
}

enum LinuxVirtualMachineCreationError: LocalizedError, Equatable, Sendable {
  case unavailable
  case rollbackFailed(preparation: String, rollback: String)

  var errorDescription: String? {
    switch self {
    case .unavailable:
      "Linux virtual machine creation is unavailable in this app configuration."
    case .rollbackFailed(let preparation, let rollback):
      "Linux virtual machine preparation failed: \(preparation) Cleanup also failed: \(rollback)"
    }
  }
}
