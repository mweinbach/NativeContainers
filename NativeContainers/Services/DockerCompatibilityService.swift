import ContainerAPIClient
import Foundation

protocol AppleContainerVersionChecking: Sendable {
  func compatibility(requiredVersion: String) async -> AppleContainerCompatibilityState
}

protocol DockerCompatibilityManaging: Sendable {
  func snapshot() async -> DockerCompatibilitySnapshot
  func installPinnedBridge() async throws
  func startBridge() async throws
  func stopBridge() async throws
  func forceStopBridge() async throws
  func createOrRepairDockerContext() async throws
}

actor DockerCompatibilityService: DockerCompatibilityManaging {
  private let installer: any SocktainerInstalling
  private let process: any SocktainerProcessManaging
  private let dockerContext: any DockerContextManaging
  private let appleContainerVersion: any AppleContainerVersionChecking

  init(
    installer: any SocktainerInstalling,
    process: any SocktainerProcessManaging,
    dockerContext: any DockerContextManaging,
    appleContainerVersion: any AppleContainerVersionChecking =
      AppleContainerHealthVersionChecker()
  ) {
    self.installer = installer
    self.process = process
    self.dockerContext = dockerContext
    self.appleContainerVersion = appleContainerVersion
  }

  func snapshot() async -> DockerCompatibilitySnapshot {
    async let installation = installer.installationState()
    async let appleContainer = appleContainerVersion.compatibility(
      requiredVersion: installer.release.version
    )
    async let runtime = process.status()
    async let context = dockerContext.status()

    return await DockerCompatibilitySnapshot(
      release: installer.release,
      installation: installation,
      appleContainer: appleContainer,
      runtime: runtime,
      dockerContext: context,
      socketURL: process.socketURL
    )
  }

  func installPinnedBridge() async throws {
    switch await process.status() {
    case .starting, .running, .stopping:
      throw DockerCompatibilityError.processAlreadyRunning
    case .stopped, .blockedByForeignSocket, .failed:
      break
    }
    try await installer.install()
  }

  func startBridge() async throws {
    guard case .ready = await installer.installationState() else {
      throw DockerCompatibilityError.installationRequired
    }

    switch await appleContainerVersion.compatibility(
      requiredVersion: installer.release.version
    ) {
    case .compatible:
      break
    case .incompatible(let found, let required):
      throw DockerCompatibilityError.incompatibleAppleContainer(
        found: found,
        required: required
      )
    case .unavailable(let reason):
      throw DockerCompatibilityError.appleContainerUnavailable(reason)
    }

    try await process.start(executableURL: installer.executableURL)
  }

  func stopBridge() async throws {
    try await process.stop()
  }

  func forceStopBridge() async throws {
    try await process.forceStop()
  }

  func createOrRepairDockerContext() async throws {
    try await dockerContext.createOrRepairContext()
  }
}

actor AppleContainerHealthVersionChecker: AppleContainerVersionChecking {
  func compatibility(requiredVersion: String) async -> AppleContainerCompatibilityState {
    do {
      let health = try await ClientHealthCheck.ping(timeout: .seconds(10))
      guard let foundVersion = Self.semanticVersion(in: health.apiServerVersion) else {
        return .unavailable(reason: "The running container API server returned an unknown version.")
      }
      guard foundVersion == requiredVersion else {
        return .incompatible(
          foundVersion: foundVersion,
          requiredVersion: requiredVersion
        )
      }
      return .compatible(version: foundVersion)
    } catch {
      return .unavailable(reason: error.localizedDescription)
    }
  }

  static func semanticVersion(in value: String) -> String? {
    value
      .split { character in
        !character.isNumber && character != "."
      }
      .map(String.init)
      .first { token in
        let components = token.split(separator: ".", omittingEmptySubsequences: false)
        return components.count == 3 && components.allSatisfy { Int($0) != nil }
      }
  }
}

actor UnavailableDockerCompatibilityService: DockerCompatibilityManaging {
  private let socketURL: URL

  init(
    socketURL: URL = FileManager.default.homeDirectoryForCurrentUser
      .appending(path: ".socktainer", directoryHint: .isDirectory)
      .appending(path: "container.sock", directoryHint: .notDirectory)
  ) {
    self.socketURL = socketURL
  }

  func snapshot() async -> DockerCompatibilitySnapshot {
    DockerCompatibilitySnapshot.initial(socketURL: socketURL)
  }

  func installPinnedBridge() async throws {
    throw DockerCompatibilityError.appleContainerUnavailable("Service unavailable")
  }

  func startBridge() async throws {
    throw DockerCompatibilityError.appleContainerUnavailable("Service unavailable")
  }

  func stopBridge() async throws {
    throw DockerCompatibilityError.processNotOwned
  }

  func forceStopBridge() async throws {
    throw DockerCompatibilityError.processNotOwned
  }

  func createOrRepairDockerContext() async throws {
    throw DockerCompatibilityError.dockerUnavailable
  }
}
