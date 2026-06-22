import Foundation

struct VirtualMachineConsoleWindowRequest:
  Codable, Equatable, Hashable, Identifiable, Sendable
{
  static let windowGroupID = "virtual-machine-console"

  let machineID: UUID
  let guest: VirtualMachineGuest

  var id: UUID { machineID }

  init(machineID: UUID, guest: VirtualMachineGuest) {
    self.machineID = machineID
    self.guest = guest
  }

  init(machine: VirtualMachineManifest) {
    self.init(machineID: machine.id, guest: machine.guest)
  }

  func resolve(
    in machines: [VirtualMachineManifest]
  ) -> VirtualMachineManifest? {
    machines.first {
      $0.id == machineID && $0.guest == guest
    }
  }
}
