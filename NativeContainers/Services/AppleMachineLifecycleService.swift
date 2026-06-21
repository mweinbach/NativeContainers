import MachineAPIClient

actor AppleMachineLifecycleService: MachineLifecycleManaging {
  private let machineClient: MachineClient

  init(machineClient: MachineClient = MachineClient()) {
    self.machineClient = machineClient
  }

  func startMachine(id: String) async throws {
    _ = try await machineClient.boot(id: id)
  }

  func stopMachine(id: String) async throws {
    try await machineClient.stop(id: id)
  }

  func deleteMachine(id: String) async throws {
    try await machineClient.delete(id: id)
  }
}
