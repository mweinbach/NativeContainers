import Foundation

protocol HostExecutableLocating: Sendable {
  func locate(candidates: [URL]) -> URL?
}

struct FixedPathHostExecutableLocator: HostExecutableLocating {
  func locate(candidates: [URL]) -> URL? {
    candidates.first {
      FileManager.default.isExecutableFile(atPath: $0.path(percentEncoded: false))
    }
  }
}

protocol DockerContextManaging: Sendable {
  func status() async -> DockerContextSnapshot
  func createOrRepairContext() async throws
}

actor DockerContextService: DockerContextManaging {
  static let contextName = "nativecontainers"

  private let socketURL: URL
  private let commandExecutor: any HostCommandExecuting
  private let executableLocator: any HostExecutableLocating
  private let environment: [String: String]
  private let dockerCandidates: [URL]

  init(
    socketURL: URL,
    commandExecutor: any HostCommandExecuting = FoundationHostCommandExecutor(),
    executableLocator: any HostExecutableLocating = FixedPathHostExecutableLocator(),
    environment: [String: String] = ProcessInfo.processInfo.environment,
    dockerCandidates: [URL] = [
      URL(filePath: "/usr/local/bin/docker"),
      URL(filePath: "/opt/homebrew/bin/docker"),
      URL(filePath: "/usr/bin/docker"),
    ]
  ) {
    self.socketURL = socketURL
    self.commandExecutor = commandExecutor
    self.executableLocator = executableLocator
    self.environment = environment
    self.dockerCandidates = dockerCandidates
  }

  func status() async -> DockerContextSnapshot {
    let overrides = environmentOverrides
    guard let dockerURL = executableLocator.locate(candidates: dockerCandidates) else {
      return DockerContextSnapshot(
        state: .dockerUnavailable,
        activeContext: nil,
        environmentOverrides: overrides
      )
    }

    do {
      let activeContext = try await readActiveContext(dockerURL: dockerURL)
      let state = try await inspectContext(dockerURL: dockerURL)
      return DockerContextSnapshot(
        state: state,
        activeContext: activeContext,
        environmentOverrides: overrides
      )
    } catch {
      return DockerContextSnapshot(
        state: .failed(error.localizedDescription),
        activeContext: nil,
        environmentOverrides: overrides
      )
    }
  }

  func createOrRepairContext() async throws {
    guard let dockerURL = executableLocator.locate(candidates: dockerCandidates) else {
      throw DockerCompatibilityError.dockerUnavailable
    }

    let activeBefore = try await readActiveContext(dockerURL: dockerURL)
    let current = try await inspectContext(dockerURL: dockerURL)
    let result: HostCommandResult

    switch current {
    case .missing:
      result = try await execute(
        dockerURL: dockerURL,
        arguments: [
          "context", "create", Self.contextName,
          "--description", "NativeContainers Socktainer \(SocktainerRelease.pinned.version)",
          "--docker", "host=\(desiredEndpoint)",
        ]
      )
    case .drifted:
      result = try await execute(
        dockerURL: dockerURL,
        arguments: [
          "context", "update", Self.contextName,
          "--description", "NativeContainers Socktainer \(SocktainerRelease.pinned.version)",
          "--docker", "host=\(desiredEndpoint)",
        ]
      )
    case .ready:
      return
    case .dockerUnavailable:
      throw DockerCompatibilityError.dockerUnavailable
    case .failed(let reason):
      throw DockerCompatibilityError.dockerContextInspectionFailed(reason)
    }

    guard result.exitCode == 0 else {
      throw DockerCompatibilityError.dockerContextMutationFailed(
        result.standardError.isEmpty ? result.standardOutput : result.standardError
      )
    }

    let activeAfter = try await readActiveContext(dockerURL: dockerURL)
    guard activeBefore == activeAfter else {
      throw DockerCompatibilityError.dockerActiveContextChanged(
        before: activeBefore,
        after: activeAfter
      )
    }

    guard try await inspectContext(dockerURL: dockerURL) == .ready else {
      throw DockerCompatibilityError.dockerContextMutationFailed(
        "Docker did not report the pinned endpoint after the update."
      )
    }
  }

  private var desiredEndpoint: String {
    "unix://\(socketURL.path(percentEncoded: false))"
  }

  private var environmentOverrides: [String] {
    ["DOCKER_CONTEXT", "DOCKER_HOST"].compactMap { name in
      guard let value = environment[name], !value.isEmpty else { return nil }
      return "\(name)=\(value)"
    }
  }

  private var sanitizedEnvironment: [String: String] {
    environment.filter { key, _ in
      key != "DOCKER_CONTEXT" && key != "DOCKER_HOST"
    }
  }

  private func readActiveContext(dockerURL: URL) async throws -> String? {
    let result = try await execute(
      dockerURL: dockerURL,
      arguments: ["context", "show"]
    )
    guard result.exitCode == 0 else {
      throw DockerCompatibilityError.dockerContextInspectionFailed(
        result.standardError.isEmpty ? result.standardOutput : result.standardError
      )
    }
    let value = result.standardOutput.trimmingCharacters(in: .whitespacesAndNewlines)
    return value.isEmpty ? nil : value
  }

  private func inspectContext(dockerURL: URL) async throws -> DockerContextSnapshot.State {
    let result = try await execute(
      dockerURL: dockerURL,
      arguments: ["context", "inspect", Self.contextName]
    )
    guard result.exitCode == 0 else {
      let message = [result.standardError, result.standardOutput]
        .joined(separator: "\n")
        .lowercased()
      if message.contains("context not found")
        || message.contains("no context exists")
        || message.contains("does not exist")
      {
        return .missing
      }
      throw DockerCompatibilityError.dockerContextInspectionFailed(
        result.standardError.isEmpty ? result.standardOutput : result.standardError
      )
    }

    do {
      let data = Data(result.standardOutput.utf8)
      let contexts = try JSONDecoder().decode([DockerContextInspection].self, from: data)
      guard
        let context = contexts.first,
        let endpoint = context.endpoints["docker"]?.host
      else {
        throw DockerCompatibilityError.dockerContextInspectionFailed(
          "Docker returned a context without a docker endpoint."
        )
      }
      return endpoint == desiredEndpoint ? .ready : .drifted(actualEndpoint: endpoint)
    } catch let error as DockerCompatibilityError {
      throw error
    } catch {
      throw DockerCompatibilityError.dockerContextInspectionFailed(
        "Docker returned invalid context JSON: \(error.localizedDescription)"
      )
    }
  }

  private func execute(
    dockerURL: URL,
    arguments: [String]
  ) async throws -> HostCommandResult {
    try await commandExecutor.execute(
      executableURL: dockerURL,
      arguments: arguments,
      environment: sanitizedEnvironment,
      timeout: .seconds(15)
    )
  }
}

private struct DockerContextInspection: Decodable {
  struct Endpoint: Decodable {
    let host: String

    enum CodingKeys: String, CodingKey {
      case host = "Host"
    }
  }

  let name: String
  let endpoints: [String: Endpoint]

  enum CodingKeys: String, CodingKey {
    case name = "Name"
    case endpoints = "Endpoints"
  }
}
