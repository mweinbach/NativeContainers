import Foundation

@MainActor
protocol VirtualMachineDiskImageRewriting: Sendable {
  func rewriteASIF(
    machineID: UUID
  ) async throws -> VirtualMachineDiskImageRewriteResult
}

@MainActor
final class VirtualMachineDiskImageRewriteService:
  VirtualMachineDiskImageRewriting
{
  private let coordinator: VirtualMachineDiskImageReplacementCoordinator

  init(coordinator: VirtualMachineDiskImageReplacementCoordinator) {
    self.coordinator = coordinator
  }

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

  func rewriteASIF(
    machineID: UUID
  ) async throws -> VirtualMachineDiskImageRewriteResult {
    try await coordinator.replace(
      machineID: machineID,
      operation: .rewriteASIF
    )
  }
}

@MainActor
struct UnavailableVirtualMachineDiskImageRewriteService:
  VirtualMachineDiskImageRewriting
{
  func rewriteASIF(
    machineID _: UUID
  ) async throws -> VirtualMachineDiskImageRewriteResult {
    throw VirtualMachineDiskImageReplacementError.unavailable
  }
}
