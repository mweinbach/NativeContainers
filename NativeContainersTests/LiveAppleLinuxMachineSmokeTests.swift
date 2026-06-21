import Foundation
import Testing

@testable import NativeContainers

@Suite(.serialized)
struct LiveAppleLinuxMachineSmokeTests {
  @Test(
    .enabled(
      if: ProcessInfo.processInfo.environment["NATIVECONTAINERS_LIVE_TESTS"] == "1",
      "Set NATIVECONTAINERS_LIVE_TESTS=1 with Apple container services running."
    )
  )
  func createProvisionStopAndDeletePersistentMachine() async throws {
    let runtime = AppleMachineRuntimeClient()
    let service = AppleMachineManagementService(
      runtime: runtime,
      runtimeMutationCoordinator: RuntimeMutationCoordinator()
    )
    let id = "nativecontainers-machine-\(UUID().uuidString.lowercased().prefix(8))"
    let request = try LinuxMachineCreationRequest(
      name: id,
      imageReference: "docker.io/library/alpine:3.22",
      cpuCount: 2,
      memoryBytes: LinuxMachineCreationRequest.minimumMemoryBytes,
      homeMount: .none,
      startAfterCreation: true
    )

    do {
      let created = try await service.createMachine(request: request) { _ in }
      #expect(created.identity.id == id)
      #expect(created.state == .running)
      #expect(created.isInitialized)

      try await service.stopMachine(created.identity)
      #expect(try await runtime.snapshot(id: id)?.state == .stopped)

      try await service.deleteMachine(created.identity)
      #expect(try await runtime.snapshot(id: id) == nil)
    } catch {
      let operationError = error
      do {
        try await cleanUp(id: id, runtime: runtime, service: service)
      } catch {
        throw LiveMachineSmokeError(
          operation: operationError.localizedDescription,
          cleanup: error.localizedDescription
        )
      }
      throw operationError
    }
  }

  private func cleanUp(
    id: String,
    runtime: AppleMachineRuntimeClient,
    service: AppleMachineManagementService
  ) async throws {
    guard var current = try await runtime.snapshot(id: id) else { return }

    if current.state != .stopped {
      do {
        try await service.stopMachine(current.identity)
      } catch {
        current = try await runtime.snapshot(id: id) ?? current
        if current.state != .stopped {
          try await service.forceStopMachine(
            current.identity,
            authorization: .confirmed(for: current.identity)
          )
        }
      }
    }

    guard let stopped = try await runtime.snapshot(id: id) else { return }
    guard stopped.state == .stopped else {
      throw LinuxMachineManagementError.forceStopNotConfirmed(id)
    }
    try await service.deleteMachine(stopped.identity)
    guard try await runtime.snapshot(id: id) == nil else {
      throw LinuxMachineManagementError.deletionNotConfirmed(id)
    }
  }
}

private struct LiveMachineSmokeError: LocalizedError {
  let operation: String
  let cleanup: String

  var errorDescription: String? {
    "Linux machine smoke failed: \(operation) Cleanup also failed: \(cleanup)"
  }
}
