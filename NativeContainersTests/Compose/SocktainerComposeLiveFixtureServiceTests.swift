import Foundation
import Testing

@testable import NativeContainers

@Suite("Socktainer Compose live fixture service")
struct SocktainerComposeLiveFixtureServiceTests {
  @Test
  func runsCanonicalFixtureAndConfirmsGracefulCleanup() async throws {
    let harness = try FixtureHarness(mode: .graceful)
    defer { harness.removeWorkspace() }

    let result = try await harness.service.run(configuration: harness.configuration)

    #expect(result.projectName == harness.configuration.projectName)
    #expect(result.observedState == .allRunning)
    #expect(result.containerID == harness.configuration.containerName)
    #expect(!result.usedFallbackCleanup)
    #expect(await harness.runtime.isEmpty)
    #expect(
      !(await harness.executor.invocations).contains(where: {
        $0.arguments.contains("--force")
      })
    )
    #expect(!FileManager.default.fileExists(atPath: harness.composeFilePath))
  }

  @Test
  func failedComposeDownUsesIdentityRevalidatedExactFallback() async throws {
    let harness = try FixtureHarness(mode: .fallback)
    defer { harness.removeWorkspace() }

    let result = try await harness.service.run(configuration: harness.configuration)
    let nativeActions = await harness.nativeCleanup.actions

    #expect(result.usedFallbackCleanup)
    #expect(await harness.runtime.isEmpty)
    #expect(nativeActions == [.container, .network, .volume])
  }

  @Test
  func cancellationStillRunsNoncancellableComposeCleanup() async throws {
    let harness = try FixtureHarness(mode: .cancelStart)
    defer { harness.removeWorkspace() }

    await #expect(throws: CancellationError.self) {
      try await harness.service.run(configuration: harness.configuration)
    }

    #expect(await harness.runtime.isEmpty)
    #expect(
      (await harness.executor.invocations).contains(where: {
        $0.arguments.contains("down")
      })
    )
    #expect(!FileManager.default.fileExists(atPath: harness.composeFilePath))
  }

  @Test
  func cleanupPlannerRefusesExactNameWithForeignLabels() throws {
    let harness = try FixtureHarness(mode: .graceful)
    defer { harness.removeWorkspace() }
    let inventory = FixtureInventoryFactory.created(
      configuration: harness.configuration,
      volumeProjectName: "foreign-project"
    )

    #expect(
      throws: SocktainerComposeLiveFixtureError.unsafeCleanupResource(
        "volume \(harness.configuration.volumeName)"
      )
    ) {
      try SocktainerComposeFixtureCleanupPlanner().plan(
        from: inventory,
        configuration: harness.configuration
      )
    }
  }

  @Test
  func cleanupIdentityRejectsRecreatedVolume() throws {
    let harness = try FixtureHarness(mode: .graceful)
    defer { harness.removeWorkspace() }
    let first = FixtureInventoryFactory.created(
      configuration: harness.configuration
    )
    let plan = try SocktainerComposeFixtureCleanupPlanner().plan(
      from: first,
      configuration: harness.configuration
    )
    let recreated = FixtureInventoryFactory.created(
      configuration: harness.configuration,
      createdAt: Date(timeIntervalSince1970: 9_999)
    )

    let volume = try #require(
      recreated.volumes.first(where: {
        $0.name == harness.configuration.volumeName
      })
    )
    #expect(plan.volume?.matches(volume) == false)
  }
}

private final class FixtureHarness: @unchecked Sendable {
  let workspaceURL: URL
  let configuration: SocktainerComposeLiveFixtureConfiguration
  let runtime: FixtureComposeRuntime
  let executor: FixtureComposeCommandExecutor
  let nativeCleanup: FixtureComposeNativeCleanup
  let service: SocktainerComposeLiveConformanceService

  var composeFilePath: String {
    workspaceURL
      .appending(path: "compose-live-fixture.yaml", directoryHint: .notDirectory)
      .nativeContainersPOSIXPath
  }

  init(mode: FixtureComposeRuntime.Mode) throws {
    let token = String(UUID().uuidString.lowercased().prefix(8))
    let projectName = "ncwire-\(token)"
    workspaceURL = FileManager.default.temporaryDirectory.appending(
      path: projectName,
      directoryHint: .isDirectory
    )
    try FileManager.default.createDirectory(
      at: workspaceURL,
      withIntermediateDirectories: false
    )
    configuration = try SocktainerComposeLiveFixtureConfiguration(
      projectName: projectName,
      workspaceURL: workspaceURL,
      composeExecutableURL: URL(filePath: "/tmp/docker-compose"),
      environment: [:],
      observationAttempts: 2,
      pollInterval: .milliseconds(1)
    )
    runtime = FixtureComposeRuntime(
      mode: mode,
      created: FixtureInventoryFactory.created(configuration: configuration),
      empty: FixtureInventoryFactory.empty
    )
    executor = FixtureComposeCommandExecutor(runtime: runtime)
    nativeCleanup = FixtureComposeNativeCleanup(runtime: runtime)
    service = SocktainerComposeLiveConformanceService(
      commandExecutor: executor,
      inventory: FixtureComposeInventoryLoader(runtime: runtime),
      nativeCleanup: nativeCleanup,
      sleep: { _ in }
    )
  }

  func removeWorkspace() {
    try? FileManager.default.removeItem(at: workspaceURL)
  }
}

private actor FixtureComposeRuntime {
  enum Mode: Sendable {
    case graceful
    case fallback
    case cancelStart
  }

  let mode: Mode
  private let created: ContainerInventory
  private let emptyInventory: ContainerInventory
  private var current: ContainerInventory

  init(
    mode: Mode,
    created: ContainerInventory,
    empty: ContainerInventory
  ) {
    self.mode = mode
    self.created = created
    emptyInventory = empty
    current = empty
  }

  var inventory: ContainerInventory { current }

  var isEmpty: Bool {
    current.containers.isEmpty
      && current.volumes.isEmpty
      && current.networks.isEmpty
  }

  func startFixture() throws {
    current = created
    if mode == .cancelStart {
      throw CancellationError()
    }
  }

  func downFixture() -> Bool {
    guard mode != .fallback else { return false }
    current = emptyInventory
    return true
  }

  func removeContainer() {
    current = ContainerInventory(
      system: current.system,
      containers: current.containers.filter {
        $0.id != created.containers[0].id
      },
      images: current.images,
      volumes: current.volumes.map { volume in
        VolumeRecord(
          id: volume.id,
          name: volume.name,
          driver: volume.driver,
          format: volume.format,
          source: volume.source,
          createdAt: volume.createdAt,
          sizeBytes: volume.sizeBytes,
          allocatedBytes: volume.allocatedBytes,
          labels: volume.labels,
          options: volume.options,
          isAnonymous: volume.isAnonymous,
          usedByContainerIDs: []
        )
      },
      networks: current.networks.map { network in
        NetworkRecord(
          id: network.id,
          name: network.name,
          mode: network.mode,
          createdAt: network.createdAt,
          configuredIPv4Subnet: network.configuredIPv4Subnet,
          configuredIPv6Subnet: network.configuredIPv6Subnet,
          assignedIPv4Subnet: network.assignedIPv4Subnet,
          ipv4Gateway: network.ipv4Gateway,
          assignedIPv6Subnet: network.assignedIPv6Subnet,
          labels: network.labels,
          plugin: network.plugin,
          options: network.options,
          isBuiltin: network.isBuiltin,
          usedByContainerIDs: []
        )
      },
      machines: current.machines
    )
  }

  func removeNetwork() {
    current = ContainerInventory(
      system: current.system,
      containers: current.containers,
      images: current.images,
      volumes: current.volumes,
      networks: [],
      machines: current.machines
    )
  }

  func removeVolume() {
    current = ContainerInventory(
      system: current.system,
      containers: current.containers,
      images: current.images,
      volumes: [],
      networks: current.networks,
      machines: current.machines
    )
  }
}

private struct FixtureComposeInventoryLoader: ContainerInventoryLoading {
  let runtime: FixtureComposeRuntime

  func loadInventory() async throws -> ContainerInventory {
    await runtime.inventory
  }
}

private actor FixtureComposeCommandExecutor: HostCommandExecuting {
  struct Invocation: Equatable, Sendable {
    let executableURL: URL
    let arguments: [String]
    let timeout: Duration
  }

  private let runtime: FixtureComposeRuntime
  private(set) var invocations: [Invocation] = []

  init(runtime: FixtureComposeRuntime) {
    self.runtime = runtime
  }

  func execute(
    executableURL: URL,
    arguments: [String],
    environment: [String: String]?,
    timeout: Duration
  ) async throws -> HostCommandResult {
    invocations.append(
      Invocation(
        executableURL: executableURL,
        arguments: arguments,
        timeout: timeout
      )
    )

    if arguments.contains("up") {
      try await runtime.startFixture()
      return .success
    }
    if arguments.contains("down") {
      if await runtime.downFixture() {
        return .success
      }
      return HostCommandResult(
        exitCode: 17,
        standardOutput: "",
        standardError: "simulated Compose teardown failure",
        outputWasTruncated: false
      )
    }
    return .success
  }
}

private actor FixtureComposeNativeCleanup:
  SocktainerComposeFixtureNativeCleaning
{
  enum Action: Equatable, Sendable {
    case container
    case network
    case volume
  }

  private let runtime: FixtureComposeRuntime
  private(set) var actions: [Action] = []

  init(runtime: FixtureComposeRuntime) {
    self.runtime = runtime
  }

  func removeContainer(_ container: ContainerRecord) async throws {
    actions.append(.container)
    await runtime.removeContainer()
  }

  func removeNetwork(_ network: NetworkRecord) async throws {
    actions.append(.network)
    await runtime.removeNetwork()
  }

  func removeVolume(_ volume: VolumeRecord) async throws {
    actions.append(.volume)
    await runtime.removeVolume()
  }
}

extension HostCommandResult {
  fileprivate static let success = HostCommandResult(
    exitCode: 0,
    standardOutput: "",
    standardError: "",
    outputWasTruncated: false
  )
}

private enum FixtureInventoryFactory {
  static let system = ContainerSystemInfo(
    version: "container-apiserver version 1.0.0",
    build: "release",
    commit: "fixture",
    applicationRoot: URL(filePath: "/tmp/container"),
    installRoot: URL(filePath: "/usr/local")
  )

  static let empty = ContainerInventory(
    system: system,
    containers: [],
    images: [],
    volumes: [],
    networks: [],
    machines: []
  )

  static func created(
    configuration: SocktainerComposeLiveFixtureConfiguration,
    volumeProjectName: String? = nil,
    createdAt: Date = Date(timeIntervalSince1970: 1_000)
  ) -> ContainerInventory {
    let container = ContainerRecord(
      id: configuration.containerName,
      imageReference: "docker.io/library/alpine:3.20",
      platform: "linux/arm64",
      state: .running,
      ipAddress: "192.0.2.2",
      createdAt: createdAt,
      startedAt: createdAt,
      cpuCount: 2,
      memoryBytes: 1_073_741_824,
      ports: [],
      labels: [
        ComposeLabelKey.project: configuration.projectName,
        ComposeLabelKey.service: "probe",
        ComposeLabelKey.containerNumber: "1",
        ComposeLabelKey.oneOff: "False",
      ]
    )
    let volume = VolumeRecord(
      id: "volume-\(configuration.volumeName)",
      name: configuration.volumeName,
      driver: "local",
      format: "ext4",
      source: "/tmp/\(configuration.volumeName)",
      createdAt: createdAt,
      sizeBytes: 64 * 1_024 * 1_024,
      allocatedBytes: 1_024,
      labels: [
        ComposeLabelKey.project: volumeProjectName ?? configuration.projectName,
        ComposeLabelKey.volume: "data",
      ],
      options: [:],
      isAnonymous: false,
      usedByContainerIDs: [container.id]
    )
    let network = NetworkRecord(
      id: "network-\(configuration.networkName)",
      name: configuration.networkName,
      mode: .nat,
      createdAt: createdAt,
      configuredIPv4Subnet: nil,
      configuredIPv6Subnet: nil,
      assignedIPv4Subnet: "192.0.2.0/24",
      ipv4Gateway: "192.0.2.1",
      assignedIPv6Subnet: nil,
      labels: [
        ComposeLabelKey.project: configuration.projectName,
        ComposeLabelKey.network: "default",
      ],
      plugin: "default",
      options: [:],
      isBuiltin: false,
      usedByContainerIDs: [container.id]
    )
    return ContainerInventory(
      system: system,
      containers: [container],
      images: [],
      volumes: [volume],
      networks: [network],
      machines: []
    )
  }
}
