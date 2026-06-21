import Foundation
import Testing

@testable import NativeContainers

@MainActor
@Suite("Docker compatibility model")
struct DockerCompatibilityModelTests {
  @Test
  func actionsRefreshPublishedSnapshot() async {
    let service = RecordingDockerCompatibilityService(snapshot: Self.stoppedSnapshot)
    let model = DockerCompatibilityModel(service: service)

    await model.load()
    #expect(model.snapshot == Self.stoppedSnapshot)

    await service.setSnapshot(Self.runningSnapshot)
    await model.start()

    #expect(await service.actions == [.start])
    #expect(model.snapshot == Self.runningSnapshot)
    #expect(model.errorMessage == nil)
    #expect(!model.isWorking)
  }

  @Test
  func operationFailureIsPublishedAndStillRefreshesStatus() async {
    let service = RecordingDockerCompatibilityService(
      snapshot: Self.runningSnapshot,
      error: DockerCompatibilityError.processNotOwned
    )
    let model = DockerCompatibilityModel(service: service)

    await model.forceStop()

    #expect(await service.actions == [.forceStop])
    #expect(model.snapshot == Self.runningSnapshot)
    #expect(model.errorMessage == DockerCompatibilityError.processNotOwned.localizedDescription)
    #expect(!model.isWorking)
  }

  @Test
  func composeClientInstallRefreshesItsIndependentSnapshot() async {
    let compatibility = RecordingDockerCompatibilityService(
      snapshot: Self.stoppedSnapshot
    )
    let composeClient = RecordingDockerComposeClientService()
    let model = DockerCompatibilityModel(
      service: compatibility,
      composeClientService: composeClient
    )

    await model.load()
    #expect(model.composeClient?.installation == .notInstalled)

    await model.installComposeClient()

    #expect(await composeClient.installCount == 1)
    #expect(model.composeClient?.installation == .ready(version: "5.1.4"))
    #expect(model.snapshot == Self.stoppedSnapshot)
    #expect(model.errorMessage == nil)
  }

  @Test
  func appModelKeepsOneSettingsScopedCompatibilityModel() {
    let service = RecordingDockerCompatibilityService(snapshot: Self.stoppedSnapshot)
    let appModel = AppModel(dockerCompatibilityService: service)

    #expect(appModel.makeDockerCompatibilityModel() === appModel.makeDockerCompatibilityModel())
  }

  private static let socketURL = URL(filePath: "/Users/test/.socktainer/container.sock")

  private static let stoppedSnapshot = DockerCompatibilitySnapshot(
    release: .pinned,
    installation: .ready(version: "1.0.0"),
    appleContainer: .compatible(version: "1.0.0"),
    runtime: .stopped,
    dockerContext: DockerContextSnapshot(
      state: .missing,
      activeContext: "orbstack",
      environmentOverrides: []
    ),
    socketURL: socketURL
  )

  private static let runningSnapshot = DockerCompatibilitySnapshot(
    release: .pinned,
    installation: .ready(version: "1.0.0"),
    appleContainer: .compatible(version: "1.0.0"),
    runtime: .running(processID: 42),
    dockerContext: DockerContextSnapshot(
      state: .ready,
      activeContext: "orbstack",
      environmentOverrides: []
    ),
    socketURL: socketURL
  )
}

private actor RecordingDockerComposeClientService: DockerComposeClientInstalling {
  nonisolated let release = DockerComposeRelease.pinned
  nonisolated let executableURL = URL(filePath: "/private/docker-compose")
  nonisolated let provenanceURL = URL(filePath: "/private/provenance.json")

  private var state = DockerComposeClientInstallationState.notInstalled
  private(set) var installCount = 0

  func snapshot() async -> DockerComposeClientSnapshot {
    DockerComposeClientSnapshot(
      release: release,
      installation: state,
      executableURL: executableURL,
      provenanceURL: provenanceURL
    )
  }

  func installationState() async -> DockerComposeClientInstallationState {
    state
  }

  func verifiedExecutableURL() async throws -> URL {
    guard case .ready = state else {
      throw DockerComposeClientError.installationRequired
    }
    return executableURL
  }

  func install() async throws {
    installCount += 1
    state = .ready(version: release.version)
  }
}

private actor RecordingDockerCompatibilityService: DockerCompatibilityManaging {
  enum Action: Equatable, Sendable {
    case install
    case start
    case stop
    case forceStop
    case removeStaleSocket
    case context
  }

  private var currentSnapshot: DockerCompatibilitySnapshot
  private let error: (any Error)?
  private(set) var actions: [Action] = []

  init(
    snapshot: DockerCompatibilitySnapshot,
    error: (any Error)? = nil
  ) {
    currentSnapshot = snapshot
    self.error = error
  }

  func setSnapshot(_ snapshot: DockerCompatibilitySnapshot) {
    currentSnapshot = snapshot
  }

  func snapshot() async -> DockerCompatibilitySnapshot {
    currentSnapshot
  }

  func installPinnedBridge() async throws {
    actions.append(.install)
    try throwConfiguredError()
  }

  func startBridge() async throws {
    actions.append(.start)
    try throwConfiguredError()
  }

  func stopBridge() async throws {
    actions.append(.stop)
    try throwConfiguredError()
  }

  func forceStopBridge() async throws {
    actions.append(.forceStop)
    try throwConfiguredError()
  }

  func removeStaleSocket() async throws {
    actions.append(.removeStaleSocket)
    try throwConfiguredError()
  }

  func createOrRepairDockerContext() async throws {
    actions.append(.context)
    try throwConfiguredError()
  }

  private func throwConfiguredError() throws {
    if let error { throw error }
  }
}
