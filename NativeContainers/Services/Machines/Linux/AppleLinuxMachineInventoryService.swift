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
        records.append(Self.record(from: machine))
        continue
      }

      do {
        records.append(Self.record(from: try await machineTransport.inspect(id: machine.id)))
      } catch is CancellationError {
        throw CancellationError()
      } catch {
        // A list snapshot can lag the first-boot marker. If inspection itself
        // is unavailable, keep the listed machine visible and retry next refresh.
        records.append(Self.record(from: machine))
      }
    }

    return records.sorted {
      $0.id.localizedStandardCompare($1.id) == .orderedAscending
    }
  }

  private static func record(from machine: MachineSnapshot) -> LinuxMachineRecord {
    LinuxMachineRecord(
      id: machine.id,
      imageReference: machine.configuration.image.reference,
      platform: String(describing: machine.platform),
      state: RuntimeState(rawValue: machine.status.rawValue) ?? .unknown,
      ipAddress: machine.ipAddress,
      createdAt: machine.createdDate,
      startedAt: machine.startedDate,
      diskSizeBytes: machine.diskSize,
      cpuCount: machine.bootConfig.cpus,
      memoryDescription: String(describing: machine.bootConfig.memory),
      isInitialized: machine.initialized
    )
  }
}
