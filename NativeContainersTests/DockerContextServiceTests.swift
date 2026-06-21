import Foundation
import Testing

@testable import NativeContainers

@Suite("Docker context service")
struct DockerContextServiceTests {
  private let dockerURL = URL(filePath: "/usr/local/bin/docker")
  private let socketURL = URL(filePath: "/Users/test/.socktainer/container.sock")

  @Test
  func reportsMissingContextWithoutChangingActiveContext() async {
    let executor = QueueHostCommandExecutor(results: [
      result(output: "orbstack\n"),
      result(exitCode: 1, error: "context \"nativecontainers\": context not found"),
    ])
    let service = makeService(executor: executor)

    let snapshot = await service.status()

    #expect(snapshot.state == .missing)
    #expect(snapshot.activeContext == "orbstack")
    #expect(
      await executor.arguments == [
        ["context", "show"],
        ["context", "inspect", "nativecontainers"],
      ])
  }

  @Test
  func distinguishesReadyAndDriftedEndpoints() async {
    let readyExecutor = QueueHostCommandExecutor(results: [
      result(output: "desktop-linux\n"),
      result(output: inspectionJSON(endpoint: desiredEndpoint)),
    ])
    let ready = await makeService(executor: readyExecutor).status()
    #expect(ready.state == .ready)

    let driftedExecutor = QueueHostCommandExecutor(results: [
      result(output: "desktop-linux\n"),
      result(output: inspectionJSON(endpoint: "unix:///tmp/other.sock")),
    ])
    let drifted = await makeService(executor: driftedExecutor).status()
    #expect(drifted.state == .drifted(actualEndpoint: "unix:///tmp/other.sock"))
  }

  @Test
  func createsProductContextWithoutUsingOrChangingGlobalContext() async throws {
    let executor = QueueHostCommandExecutor(results: [
      result(output: "orbstack\n"),
      result(exitCode: 1, error: "context not found"),
      result(output: "created\n"),
      result(output: "orbstack\n"),
      result(output: inspectionJSON(endpoint: desiredEndpoint)),
    ])
    let service = makeService(executor: executor)

    try await service.createOrRepairContext()

    let arguments = await executor.arguments
    #expect(arguments.contains { $0.prefix(3) == ["context", "create", "nativecontainers"] })
    #expect(!arguments.contains { $0.prefix(2) == ["context", "use"] })
    #expect(!arguments.contains { $0.prefix(2) == ["context", "rm"] })
  }

  @Test
  func repairsDriftWithContextUpdateRatherThanDestructiveRemoval() async throws {
    let executor = QueueHostCommandExecutor(results: [
      result(output: "default\n"),
      result(output: inspectionJSON(endpoint: "unix:///tmp/wrong.sock")),
      result(output: "updated\n"),
      result(output: "default\n"),
      result(output: inspectionJSON(endpoint: desiredEndpoint)),
    ])
    let service = makeService(executor: executor)

    try await service.createOrRepairContext()

    let arguments = await executor.arguments
    #expect(arguments.contains { $0.prefix(3) == ["context", "update", "nativecontainers"] })
    #expect(!arguments.contains { $0.prefix(2) == ["context", "rm"] })
    #expect(!arguments.contains { $0.prefix(2) == ["context", "use"] })
  }

  @Test
  func detectsButSanitizesDockerEnvironmentOverrides() async {
    let executor = QueueHostCommandExecutor(results: [
      result(output: "default\n"),
      result(output: inspectionJSON(endpoint: desiredEndpoint)),
    ])
    let service = makeService(
      executor: executor,
      environment: [
        "PATH": "/usr/bin",
        "DOCKER_CONTEXT": "remote",
        "DOCKER_HOST": "tcp://example:2375",
      ]
    )

    let snapshot = await service.status()

    #expect(
      snapshot.environmentOverrides == [
        "DOCKER_CONTEXT=remote",
        "DOCKER_HOST=tcp://example:2375",
      ])
    let environments = await executor.environments
    #expect(environments.allSatisfy { $0?["PATH"] == "/usr/bin" })
    #expect(environments.allSatisfy { $0?["DOCKER_CONTEXT"] == nil })
    #expect(environments.allSatisfy { $0?["DOCKER_HOST"] == nil })
  }

  @Test
  func failsIfDockerUnexpectedlyChangesTheActiveContext() async {
    let executor = QueueHostCommandExecutor(results: [
      result(output: "orbstack\n"),
      result(exitCode: 1, error: "context not found"),
      result(output: "created\n"),
      result(output: "nativecontainers\n"),
    ])
    let service = makeService(executor: executor)

    await #expect(
      throws: DockerCompatibilityError.dockerActiveContextChanged(
        before: "orbstack",
        after: "nativecontainers"
      )
    ) {
      try await service.createOrRepairContext()
    }
  }

  @Test
  func reportsDockerUnavailableWithoutExecutingCommands() async {
    let executor = QueueHostCommandExecutor(results: [])
    let service = DockerContextService(
      socketURL: socketURL,
      commandExecutor: executor,
      executableLocator: StaticExecutableLocator(url: nil),
      environment: [:],
      dockerCandidates: [dockerURL]
    )

    let snapshot = await service.status()

    #expect(snapshot.state == .dockerUnavailable)
    #expect(await executor.arguments.isEmpty)
  }

  private var desiredEndpoint: String {
    "unix://\(socketURL.path(percentEncoded: false))"
  }

  private func makeService(
    executor: QueueHostCommandExecutor,
    environment: [String: String] = [:]
  ) -> DockerContextService {
    DockerContextService(
      socketURL: socketURL,
      commandExecutor: executor,
      executableLocator: StaticExecutableLocator(url: dockerURL),
      environment: environment,
      dockerCandidates: [dockerURL]
    )
  }

  private func inspectionJSON(endpoint: String) -> String {
    """
    [{"Name":"nativecontainers","Endpoints":{"docker":{"Host":"\(endpoint)"}}}]
    """
  }

  private func result(
    exitCode: Int32 = 0,
    output: String = "",
    error: String = ""
  ) -> HostCommandResult {
    HostCommandResult(
      exitCode: exitCode,
      standardOutput: output,
      standardError: error,
      outputWasTruncated: false
    )
  }
}

private struct StaticExecutableLocator: HostExecutableLocating {
  let url: URL?

  func locate(candidates: [URL]) -> URL? {
    url
  }
}

private actor QueueHostCommandExecutor: HostCommandExecuting {
  private var results: [HostCommandResult]
  private(set) var arguments: [[String]] = []
  private(set) var environments: [[String: String]?] = []

  init(results: [HostCommandResult]) {
    self.results = results
  }

  func execute(
    executableURL: URL,
    arguments: [String],
    environment: [String: String]?,
    timeout: Duration
  ) async throws -> HostCommandResult {
    self.arguments.append(arguments)
    environments.append(environment)
    guard !results.isEmpty else {
      Issue.record("Unexpected host command: \(arguments.joined(separator: " "))")
      return HostCommandResult(
        exitCode: 99,
        standardOutput: "",
        standardError: "Unexpected command",
        outputWasTruncated: false
      )
    }
    return results.removeFirst()
  }
}
