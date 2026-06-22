import Foundation
import Testing

@testable import NativeContainers

struct VirtualMachineSavedStateReclamationServiceTests {
  @Test
  func routesSavedStatePlanningAndReclamationByGuest() async throws {
    let macID = UUID()
    let linuxID = UUID()
    let missingID = UUID()
    let inventory = SavedStateReclamationInventory(
      manifests: [
        try makeReclamationManifest(id: macID, guest: .macOS, name: "Mac"),
        try makeReclamationManifest(id: linuxID, guest: .linux, name: "Linux"),
      ]
    )
    let mac = RecordingSavedStateReclaimer(names: [macID: "Mac"])
    let linux = RecordingSavedStateReclaimer(names: [linuxID: "Linux"])
    let service = GuestAwareVirtualMachineSavedStateReclamationService(
      inventory: inventory,
      macOS: mac,
      linux: linux
    )

    let plan = try await service.prepareSavedStateReclamation(
      machineIDs: [macID, linuxID, missingID]
    )

    #expect(await mac.preparedMachineIDs == [macID])
    #expect(await linux.preparedMachineIDs == [linuxID])
    #expect(Set(plan.candidates.map(\.machineID)) == [macID, linuxID])
    #expect(plan.issues.map(\.machineID) == [missingID])

    let result = try await service.reclaimSavedStates(plan)

    #expect(await mac.reclaimedMachineIDs == [macID])
    #expect(await linux.reclaimedMachineIDs == [linuxID])
    #expect(
      Set(result.removedCandidateIDs)
        == Set(plan.candidates.map(\.id))
    )
  }
}

private struct SavedStateReclamationInventory:
  VirtualMachineInventoryLoading
{
  let manifests: [VirtualMachineManifest]

  func list() -> [VirtualMachineManifest] {
    manifests
  }
}

private actor RecordingSavedStateReclaimer:
  VirtualMachineSavedStateStorageReclaiming
{
  let names: [UUID: String]
  private(set) var preparedMachineIDs: Set<UUID> = []
  private(set) var reclaimedMachineIDs: Set<UUID> = []

  init(names: [UUID: String]) {
    self.names = names
  }

  func prepareSavedStateReclamation(
    machineIDs: Set<UUID>
  ) -> VirtualMachineSavedStateReclamationPlan {
    preparedMachineIDs = machineIDs
    return VirtualMachineSavedStateReclamationPlan(
      candidates: machineIDs.compactMap { id in
        names[id].map { makeReclamationCandidate(id: id, name: $0) }
      },
      issues: []
    )
  }

  func reclaimSavedStates(
    _ plan: VirtualMachineSavedStateReclamationPlan
  ) -> VirtualMachineStorageReclamationBatchResult {
    reclaimedMachineIDs = Set(plan.candidates.map(\.machineID))
    return VirtualMachineStorageReclamationBatchResult(
      removedCandidateIDs: plan.candidates.map(\.id),
      staleCandidateIDs: [],
      failedCandidates: [],
      removedAllocatedBytes: plan.candidates.reduce(0) {
        $0 + $1.estimatedAllocatedBytes
      }
    )
  }
}

private func makeReclamationManifest(
  id: UUID,
  guest: VirtualMachineGuest,
  name: String
) throws -> VirtualMachineManifest {
  try VirtualMachineManifest(
    id: id,
    name: name,
    guest: guest,
    installState: .stopped,
    resources: VirtualMachineResources(
      cpuCount: 2,
      memoryBytes: 2 * VirtualMachineResources.bytesPerGiB,
      diskBytes: 8 * VirtualMachineResources.bytesPerGiB
    )
  )
}

private func makeReclamationCandidate(
  id: UUID,
  name: String
) -> VirtualMachineSavedStateReclamationCandidate {
  VirtualMachineSavedStateReclamationCandidate(
    machineID: id,
    machineName: name,
    createdAt: Date(timeIntervalSince1970: 1_000),
    stateSizeBytes: 4_096,
    configurationFingerprint: "fingerprint-\(id.uuidString)",
    artifactIdentity: VirtualMachineStorageArtifactIdentity(
      device: 1,
      inode: 2,
      fileType: .directory,
      ownerUserID: 501,
      linkCount: 1,
      logicalBytes: 4_096,
      allocatedBytes: 4_096,
      entryCount: 2,
      modificationSeconds: 1_000,
      modificationNanoseconds: 0,
      statusChangeSeconds: 1_000,
      statusChangeNanoseconds: 0,
      treeFingerprint: "tree-\(id.uuidString)"
    )
  )
}
