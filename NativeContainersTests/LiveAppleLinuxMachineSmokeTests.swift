import Darwin
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
  func createUseStopAndDeletePersistentMachine() async throws {
    let machineTransport = AppleMachineXPCTransport()
    let processClient = AppleContainerProcessXPCClient()
    let runtime = AppleMachineRuntimeClient(
      machineTransport: machineTransport,
      processClient: processClient
    )
    let service = AppleMachineManagementService(
      runtime: runtime,
      runtimeMutationCoordinator: RuntimeMutationCoordinator()
    )
    let processService = AppleLinuxMachineProcessService(
      targetResolver: AppleLinuxMachineProcessTargetResolver(
        lifecycle: service,
        machineTransport: machineTransport
      ),
      commandExecutor: AppleRuntimeCommandExecutor(processClient: processClient),
      processClient: processClient
    )
    let id = "nativecontainers-machine-\(UUID().uuidString.lowercased().prefix(8))"
    let request = try LinuxMachineCreationRequest(
      name: id,
      imageReference: "docker.io/library/alpine:3.22",
      cpuCount: 2,
      memoryBytes: LinuxMachineCreationRequest.minimumMemoryBytes,
      homeMount: .none,
      startAfterCreation: false
    )
    var terminalSession: (any ContainerTerminalSession)?
    var terminalOutputTask: Task<Void, Never>?

    do {
      let created = try await service.createMachine(request: request) { _ in }
      #expect(created.identity.id == id)
      #expect(created.state == .stopped)
      #expect(!created.isInitialized)

      let command = try await processService.executeCommand(
        in: created.identity,
        request: LinuxMachineCommandRequest(command: "id -u; pwd; uname -s")
      )
      #expect(command.exitCode == 0)
      #expect(command.standardOutput.contains("\(getuid())"))
      #expect(command.standardOutput.contains("/home/"))
      #expect(command.standardOutput.contains("Linux"))

      let refreshed = try await runtime.snapshot(id: id)
      let ready = try #require(refreshed)
      #expect(ready.state == .running)
      #expect(ready.isInitialized)

      let terminal = try await processService.openTerminal(
        in: created.identity,
        request: LinuxMachineTerminalRequest(
          initialSize: try ContainerTerminalSize(columns: 93, rows: 31)
        )
      )
      terminalSession = terminal
      terminalOutputTask = Task {
        for await _ in terminal.output {}
      }
      try await terminal.sendInput(Data("printf 'native-terminal-ready\\n'; exit\n".utf8))
      #expect(try await terminal.wait() == 0)
      await terminalOutputTask?.value
      #expect((await terminal.snapshot()).retainedText.contains("native-terminal-ready"))

      await #expect(throws: ContainerToolValidationError.commandTimedOut(1)) {
        try await processService.executeCommand(
          in: created.identity,
          request: LinuxMachineCommandRequest(command: "sleep 30", timeoutSeconds: 1)
        )
      }

      let afterKill = try await processService.executeCommand(
        in: created.identity,
        request: LinuxMachineCommandRequest(command: "printf machine-still-running")
      )
      #expect(afterKill.standardOutput == "machine-still-running")

      try await service.stopMachine(created.identity)
      #expect(try await runtime.snapshot(id: id)?.state == .stopped)

      try await service.deleteMachine(created.identity)
      #expect(try await runtime.snapshot(id: id) == nil)
    } catch {
      let operationError = error
      terminalOutputTask?.cancel()
      await terminalSession?.close()
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
