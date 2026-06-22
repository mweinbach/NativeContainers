import Foundation
import Testing

@testable import NativeContainers

@Suite("Virtual machine console window routing")
struct VirtualMachineConsoleWindowModelsTests {
  @Test
  func requestRoundTripsWithStableMachineIdentity() throws {
    let machine = try makeManifest(name: "macOS", guest: .macOS)
    let request = VirtualMachineConsoleWindowRequest(machine: machine)

    let encoded = try JSONEncoder().encode(request)
    let decoded = try JSONDecoder().decode(
      VirtualMachineConsoleWindowRequest.self,
      from: encoded
    )

    #expect(decoded == request)
    #expect(decoded.id == machine.id)
    #expect(decoded.guest == .macOS)
  }

  @Test
  func restoredRequestResolvesTheCurrentManifest() throws {
    var machine = try makeManifest(name: "Original", guest: .linux)
    let request = VirtualMachineConsoleWindowRequest(machine: machine)
    machine.name = "Renamed"

    #expect(request.resolve(in: [machine]) == machine)
  }

  @Test
  func restoredRequestRejectsMissingAndGuestMismatchedMachines() throws {
    let machine = try makeManifest(name: "macOS", guest: .macOS)
    let missing = VirtualMachineConsoleWindowRequest(
      machineID: UUID(),
      guest: .macOS
    )
    let mismatched = VirtualMachineConsoleWindowRequest(
      machineID: machine.id,
      guest: .linux
    )

    #expect(missing.resolve(in: [machine]) == nil)
    #expect(mismatched.resolve(in: [machine]) == nil)
  }

  private func makeManifest(
    name: String,
    guest: VirtualMachineGuest
  ) throws -> VirtualMachineManifest {
    try VirtualMachineManifest(
      name: name,
      guest: guest,
      installState: .stopped,
      resources: VirtualMachineResources(
        cpuCount: 4,
        memoryBytes: 8 * VirtualMachineResources.bytesPerGiB,
        diskBytes: 64 * VirtualMachineResources.bytesPerGiB
      )
    )
  }
}
