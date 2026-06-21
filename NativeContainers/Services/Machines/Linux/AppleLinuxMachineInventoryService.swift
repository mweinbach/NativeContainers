import Foundation
import MachineAPIClient

struct AppleLinuxMachineInventoryService: LinuxMachineInventoryLoading {
  private let machineTransport: any AppleMachineTransport

  init(machineTransport: any AppleMachineTransport = AppleMachineXPCTransport()) {
    self.machineTransport = machineTransport
  }

  func loadMachines() async throws -> [LinuxMachineRecord] {
    let listed = try await machineTransport.list()
    var records: [LinuxMachineRecord] = []
    records.reserveCapacity(listed.count)

    for machine in listed {
      try Task.checkCancellation()
      guard !machine.initialized else {
        records.append(try AppleLinuxMachineSnapshotMapper.record(from: machine))
        continue
      }

      do {
        records.append(
          try AppleLinuxMachineSnapshotMapper.record(
            from: try await machineTransport.inspect(id: machine.id)
          )
        )
      } catch is CancellationError {
        throw CancellationError()
      } catch {
        // A list snapshot can lag the first-boot marker. If inspection itself
        // is unavailable, keep the listed machine visible and retry next refresh.
        records.append(try AppleLinuxMachineSnapshotMapper.record(from: machine))
      }
    }

    return records.sorted {
      $0.id.localizedStandardCompare($1.id) == .orderedAscending
    }
  }

}
