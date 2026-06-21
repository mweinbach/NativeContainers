import Foundation
import Testing

@testable import NativeContainers

@Suite("Identity-pinned terminal targets")
struct TerminalTargetServiceTests {
  @Test
  func opensExactContainerThroughContainerTerminalFacet() async throws {
    let container = makeContainer(createdAt: Date(timeIntervalSince1970: 10))
    let inventory = TerminalInventoryStub(containers: [container])
    let containerTerminal = ContainerTerminalOpeningRecorder()
    let machineTerminal = MachineTerminalOpeningRecorder()
    let service = IdentityPinnedTerminalTargetService(
      inventory: inventory,
      containerTerminal: containerTerminal,
      machineTerminal: machineTerminal
    )
    let request = try ContainerTerminalRequest(
      program: .executable("/bin/bash"),
      arguments: ["-l"]
    )

    _ = try await service.openTerminal(
      for: .container(ContainerTerminalTargetIdentity(container: container)),
      request: request
    )

    #expect(await containerTerminal.containerIDs == ["dev"])
    #expect(await containerTerminal.requests == [request])
    #expect(await machineTerminal.targets.isEmpty)
  }

  @Test
  func rejectsSameNameContainerReplacementBeforeOpeningProcess() async throws {
    let reviewed = makeContainer(createdAt: Date(timeIntervalSince1970: 10))
    let replacement = makeContainer(createdAt: Date(timeIntervalSince1970: 20))
    let inventory = TerminalInventoryStub(containers: [replacement])
    let containerTerminal = ContainerTerminalOpeningRecorder()
    let service = IdentityPinnedTerminalTargetService(
      inventory: inventory,
      containerTerminal: containerTerminal,
      machineTerminal: MachineTerminalOpeningRecorder()
    )

    await #expect(throws: TerminalWorkspaceError.containerIdentityChanged("dev")) {
      _ = try await service.openTerminal(
        for: .container(ContainerTerminalTargetIdentity(container: reviewed)),
        request: try ContainerTerminalRequest()
      )
    }
    #expect(await containerTerminal.containerIDs.isEmpty)
  }

  @Test
  func opensExactLinuxMachineThroughLoginShellFacet() async throws {
    let machine = makeMachine(createdAt: Date(timeIntervalSince1970: 10))
    let identity = LinuxMachineIdentity(machine: machine)
    let inventory = TerminalInventoryStub(machines: [machine])
    let containerTerminal = ContainerTerminalOpeningRecorder()
    let machineTerminal = MachineTerminalOpeningRecorder()
    let service = IdentityPinnedTerminalTargetService(
      inventory: inventory,
      containerTerminal: containerTerminal,
      machineTerminal: machineTerminal
    )
    let request = try ContainerTerminalRequest(workingDirectory: "/workspace")

    _ = try await service.openTerminal(
      for: .linuxMachine(identity),
      request: request
    )

    #expect(await machineTerminal.targets == [identity])
    #expect(await machineTerminal.requests.first?.workingDirectory == "/workspace")
    #expect(await containerTerminal.containerIDs.isEmpty)
  }

  @Test
  func rejectsSameNameLinuxMachineReplacementBeforeStartingIt() async throws {
    let reviewed = makeMachine(createdAt: Date(timeIntervalSince1970: 10))
    let replacement = makeMachine(createdAt: Date(timeIntervalSince1970: 20))
    let identity = LinuxMachineIdentity(machine: reviewed)
    let inventory = TerminalInventoryStub(machines: [replacement])
    let machineTerminal = MachineTerminalOpeningRecorder()
    let service = IdentityPinnedTerminalTargetService(
      inventory: inventory,
      containerTerminal: ContainerTerminalOpeningRecorder(),
      machineTerminal: machineTerminal
    )

    await #expect(throws: TerminalWorkspaceError.linuxMachineIdentityChanged("dev-machine")) {
      _ = try await service.openTerminal(
        for: .linuxMachine(identity),
        request: try ContainerTerminalRequest()
      )
    }
    #expect(await machineTerminal.targets.isEmpty)
  }

  private func makeContainer(createdAt: Date) -> ContainerRecord {
    ContainerRecord(
      id: "dev",
      imageReference: "docker.io/library/alpine:3.21",
      platform: "linux/arm64",
      state: .running,
      ipAddress: nil,
      createdAt: createdAt,
      startedAt: createdAt,
      cpuCount: 2,
      memoryBytes: 512 * 1_024 * 1_024,
      ports: []
    )
  }

  private func makeMachine(createdAt: Date) -> LinuxMachineRecord {
    LinuxMachineRecord(
      id: "dev-machine",
      imageReference: "docker.io/library/ubuntu:24.04",
      platform: "linux/arm64",
      state: .stopped,
      ipAddress: nil,
      createdAt: createdAt,
      startedAt: nil,
      diskSizeBytes: nil,
      cpuCount: 4,
      memoryBytes: 4 * 1_024 * LinuxMachineConfiguration.bytesPerMiB,
      homeMount: .none,
      isInitialized: true
    )
  }
}

private actor TerminalInventoryStub: ContainerInventoryLoading {
  private let containers: [ContainerRecord]
  private let machines: [LinuxMachineRecord]

  init(
    containers: [ContainerRecord] = [],
    machines: [LinuxMachineRecord] = []
  ) {
    self.containers = containers
    self.machines = machines
  }

  func loadInventory() -> ContainerInventory {
    ContainerInventory(
      system: ContainerSystemInfo(
        version: "1.0.0",
        build: "test",
        commit: "test",
        applicationRoot: URL(filePath: "/tmp/container"),
        installRoot: URL(filePath: "/usr/local")
      ),
      containers: containers,
      images: [],
      volumes: [],
      networks: [],
      machines: machines
    )
  }
}

private actor ContainerTerminalOpeningRecorder: ContainerTerminalOpening {
  private(set) var containerIDs: [String] = []
  private(set) var requests: [ContainerTerminalRequest] = []

  func openTerminal(
    in id: String,
    request: ContainerTerminalRequest
  ) -> any ContainerTerminalSession {
    containerIDs.append(id)
    requests.append(request)
    return TerminalTargetSession()
  }
}

private actor MachineTerminalOpeningRecorder: MachineTerminalOpening {
  private(set) var targets: [LinuxMachineIdentity] = []
  private(set) var requests: [LinuxMachineTerminalRequest] = []

  func openTerminal(
    in target: LinuxMachineIdentity,
    request: LinuxMachineTerminalRequest
  ) -> any ContainerTerminalSession {
    targets.append(target)
    requests.append(request)
    return TerminalTargetSession()
  }
}

private actor TerminalTargetSession: ContainerTerminalSession {
  nonisolated let output = AsyncStream<Data> { continuation in
    continuation.finish()
  }

  func sendInput(_ data: Data) {}

  func resize(to size: ContainerTerminalSize) {}

  func sendSignal(_ signal: ContainerTerminalSignal) {}

  func snapshot() -> ContainerTerminalSnapshot {
    ContainerTerminalSnapshot(
      lifecycle: .running,
      retainedOutput: Data(),
      outputWasTruncated: false
    )
  }

  func wait() -> Int32 {
    0
  }

  func close() {}
}
