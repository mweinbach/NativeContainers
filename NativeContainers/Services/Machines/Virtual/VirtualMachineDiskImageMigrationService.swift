import Foundation

typealias VirtualMachineDiskImageMigrationStoring =
  VirtualMachineDiskImageReplacementStoring

@MainActor
protocol VirtualMachineDiskImageMigrating: Sendable {
  func migrateToASIF(
    machineID: UUID
  ) async throws -> VirtualMachineDiskImageMigrationResult
}

@MainActor
protocol VirtualMachineDiskImageMigrationManaging:
  VirtualMachineDiskImageMigrating
{}

@MainActor
final class VirtualMachineDiskImageMigrationService:
  VirtualMachineDiskImageMigrationManaging
{
  private let coordinator: VirtualMachineDiskImageReplacementCoordinator

  init(
    store: any VirtualMachineDiskImageReplacementStoring,
    savedStates: any MacVirtualMachineSavedStateInspecting,
    converter: any VirtualMachineDiskImageConverting =
      DiskutilVirtualMachineDiskImageConverter(),
    imageInspector: any VirtualMachineDiskImageInspecting =
      AppleVirtualMachineDiskImageInspector(),
    artifactInspector: any VirtualMachineStorageArtifactInspecting =
      FileVirtualMachineStorageArtifactInspector(),
    journalStore: any VirtualMachineDiskImageReplacementJournaling =
      FileVirtualMachineDiskImageReplacementJournalStore(),
    hostBootSession: any HostBootSessionIdentifying =
      DarwinHostBootSessionIdentifier(),
    fileManager: FileManager = .default
  ) {
    coordinator = VirtualMachineDiskImageReplacementCoordinator(
      store: store,
      savedStates: savedStates,
      converter: converter,
      imageInspector: imageInspector,
      artifactInspector: artifactInspector,
      journalStore: journalStore,
      hostBootSession: hostBootSession,
      fileManager: fileManager
    )
  }

  init(coordinator: VirtualMachineDiskImageReplacementCoordinator) {
    self.coordinator = coordinator
  }

  func migrateToASIF(
    machineID: UUID
  ) async throws -> VirtualMachineDiskImageMigrationResult {
    try await coordinator.replace(
      machineID: machineID,
      operation: .rawToASIF
    )
  }

}

@MainActor
struct UnavailableVirtualMachineDiskImageMigrationService:
  VirtualMachineDiskImageMigrationManaging
{
  func migrateToASIF(
    machineID _: UUID
  ) async throws -> VirtualMachineDiskImageMigrationResult {
    throw VirtualMachineDiskImageReplacementError.unavailable
  }
}
