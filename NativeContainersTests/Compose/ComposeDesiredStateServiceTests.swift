import Foundation
import Testing

@testable import NativeContainers

@Suite("Docker Compose canonical configuration")
struct DockerComposeConfigServiceTests {
  @Test
  func rendersFullAndActiveModelsWithPinnedExplicitInputs() async throws {
    let executor = ComposeCommandExecutorDouble(results: [
      commandResult(fullJSON),
      commandResult(activeJSON),
      commandResult(
        "web \(String(repeating: "a", count: 64))\nworker \(String(repeating: "b", count: 64))\n"
      ),
    ])
    let service = DockerComposeConfigService(
      composeClient: ReadyComposeClientDouble(),
      commandExecutor: executor,
      processEnvironment: [
        "HOME": "/Users/test",
        "PATH": "/usr/bin",
        "DOCKER_HOST": "tcp://remote.invalid:2375",
        "COMPOSE_PROJECT_NAME": "hijack",
        "SECRET_TOKEN": "do-not-forward",
      ]
    )
    let options = ComposeProjectReviewOptions(
      action: .up,
      projectName: "demo",
      profiles: ["jobs"]
    )

    let rendered = try await service.render(source: sourceLease, options: options)

    #expect(rendered.composeReleaseVersion == DockerComposeRelease.pinned.version)
    #expect(rendered.fullConfigurationSHA256.count == 64)
    #expect(rendered.activeConfigurationSHA256.count == 64)
    #expect(rendered.serviceConfigurationHashes.keys.sorted() == ["web", "worker"])

    let arguments = await executor.arguments
    #expect(arguments.count == 3)
    #expect(arguments[0].containsSubsequence(["--profile", "*"]))
    #expect(arguments[1].containsSubsequence(["--profile", "jobs"]))
    #expect(arguments.allSatisfy { $0.containsSubsequence(["--project-name", "demo"]) })
    #expect(
      arguments.prefix(2).allSatisfy {
        $0.suffix(4) == ["config", "--format", "json", "--no-env-resolution"]
      })
    #expect(arguments[2].suffix(3) == ["config", "--hash", "*"])

    let environments = await executor.environments
    #expect(environments.allSatisfy { $0?["HOME"] == "/Users/test" })
    #expect(environments.allSatisfy { $0?["COMPOSE_DISABLE_ENV_FILE"] == "true" })
    #expect(environments.allSatisfy { $0?["DOCKER_HOST"] == nil })
    #expect(environments.allSatisfy { $0?["COMPOSE_PROJECT_NAME"] == nil })
    #expect(environments.allSatisfy { $0?["SECRET_TOKEN"] == nil })
  }

  @Test
  func failsClosedWhenCanonicalOutputIsTruncated() async {
    let executor = ComposeCommandExecutorDouble(results: [
      HostCommandResult(
        exitCode: 0,
        standardOutput: fullJSON,
        standardError: "",
        outputWasTruncated: true
      )
    ])
    let service = DockerComposeConfigService(
      composeClient: ReadyComposeClientDouble(),
      commandExecutor: executor
    )

    await #expect(throws: ComposeProjectLifecycleError.configOutputTruncated) {
      _ = try await service.render(
        source: sourceLease,
        options: ComposeProjectReviewOptions(action: .up, projectName: "demo")
      )
    }
  }

  @Test
  func rejectsDuplicatedOrMalformedServiceConfigurationHashes() async {
    let hash = String(repeating: "a", count: 64)
    let executor = ComposeCommandExecutorDouble(results: [
      commandResult(fullJSON),
      commandResult(activeJSON),
      commandResult("web \(hash)\nweb \(hash)\n"),
    ])
    let service = DockerComposeConfigService(
      composeClient: ReadyComposeClientDouble(),
      commandExecutor: executor
    )

    await #expect(throws: ComposeProjectLifecycleError.self) {
      _ = try await service.render(
        source: sourceLease,
        options: ComposeProjectReviewOptions(action: .up, projectName: "demo")
      )
    }
  }

  @Test
  func rejectsTruncatedServiceConfigurationHashOutput() async {
    let executor = ComposeCommandExecutorDouble(results: [
      commandResult(fullJSON),
      commandResult(activeJSON),
      HostCommandResult(
        exitCode: 0,
        standardOutput: "web \(String(repeating: "a", count: 64))\n",
        standardError: "",
        outputWasTruncated: true
      ),
    ])
    let service = DockerComposeConfigService(
      composeClient: ReadyComposeClientDouble(),
      commandExecutor: executor
    )

    await #expect(throws: ComposeProjectLifecycleError.configOutputTruncated) {
      _ = try await service.render(
        source: sourceLease,
        options: ComposeProjectReviewOptions(action: .up, projectName: "demo")
      )
    }
  }

  @Test
  func rejectsInterpolationWarningsWithoutRetainingTheirValues() async {
    let executor = ComposeCommandExecutorDouble(results: [
      HostCommandResult(
        exitCode: 0,
        standardOutput: fullJSON,
        standardError: "The PRIVATE_TOKEN variable is not set.",
        outputWasTruncated: false
      )
    ])
    let service = DockerComposeConfigService(
      composeClient: ReadyComposeClientDouble(),
      commandExecutor: executor
    )

    await #expect(throws: ComposeProjectLifecycleError.self) {
      _ = try await service.render(
        source: sourceLease,
        options: ComposeProjectReviewOptions(action: .up, projectName: "demo")
      )
    }
  }

  private var sourceLease: ComposeProjectSourceLease {
    ComposeProjectSourceLease(
      id: UUID(),
      directoryURL: URL(filePath: "/private/tmp/demo", directoryHint: .isDirectory),
      composeFileURL: URL(filePath: "/private/tmp/demo/compose.yaml"),
      summary: ComposeProjectSourceSummary(
        directoryName: "demo",
        fileName: "compose.yaml",
        fileIdentity: sourceIdentity
      )
    )
  }

  private var sourceIdentity: ComposeProjectSourceFileIdentity {
    ComposeProjectSourceFileIdentity(
      device: 1,
      inode: 2,
      owner: 501,
      permissions: 0o600,
      byteCount: 10,
      modificationSeconds: 1,
      modificationNanoseconds: 0,
      changeSeconds: 1,
      changeNanoseconds: 0,
      sha256: String(repeating: "a", count: 64)
    )
  }

  private var fullJSON: String {
    """
    {
      "volumes": {"data": {"external": false, "name": "demo_data"}},
      "services": {
        "worker": {"profiles": ["jobs"], "image": "alpine:3.20"},
        "web": {"image": "nginx:1.27"}
      },
      "name": "demo"
    }
    """
  }

  private var activeJSON: String {
    """
    {
      "name": "demo",
      "services": {
        "web": {"image": "nginx:1.27"}
      }
    }
    """
  }

  private func commandResult(_ output: String) -> HostCommandResult {
    HostCommandResult(
      exitCode: 0,
      standardOutput: output,
      standardError: "",
      outputWasTruncated: false
    )
  }
}

@Suite("Compose desired-state decoder")
struct ComposeDesiredStateDecoderTests {
  private let decoder = ComposeDesiredStateDecoder()

  @Test
  func keepsFullDeclarationBoundarySeparateFromActiveServices() throws {
    let rendered = renderedConfiguration(
      full: """
        {
          "name": "demo",
          "services": {
            "web": {
              "image": "nginx:1.27",
              "profiles": [],
              "volumes": [{"type": "volume", "source": "data", "target": "/data", "volume": {}}],
              "networks": {"default": {}},
              "ports": [{"target": 80, "published": "8080", "protocol": "tcp"}]
            },
            "worker": {
              "image": "alpine:3.20",
              "profiles": ["jobs"],
              "environment": {"TOKEN": "not-retained"},
              "networks": {"default": {}}
            }
          },
          "volumes": {"data": {"name": "demo_data", "external": false}},
          "networks": {"default": {"name": "demo_default", "external": false, "ipam": {}}}
        }
        """,
      active: """
        {
          "name": "demo",
          "services": {
            "web": {
              "image": "nginx:1.27",
              "profiles": [],
              "volumes": [{"type": "volume", "source": "data", "target": "/data", "volume": {}}],
              "networks": {"default": {}},
              "ports": [{"target": 80, "published": "8080", "protocol": "tcp"}]
            }
          },
          "volumes": {"data": {"name": "demo_data", "external": false}},
          "networks": {"default": {"name": "demo_default", "external": false, "ipam": {}}}
        }
        """
    )

    let review = try decoder.decode(rendered: rendered, expectedProjectName: "demo")

    #expect(review.desiredState.declaredServiceNames == ["web", "worker"])
    #expect(review.desiredState.activeServiceNames == ["web"])
    #expect(review.desiredState.activeServices.first?.volumeNames == ["data"])
    #expect(review.desiredState.activeServices.first?.networkNames == ["default"])
    #expect(review.desiredState.activeServices.first?.publishedPortCount == 1)
    #expect(review.desiredState.volumes.first?.runtimeName == "demo_data")
    #expect(review.desiredState.networks.first?.runtimeName == "demo_default")
    #expect(review.issues.isEmpty)
  }

  @Test
  func blocksUnsupportedFeaturesWithoutRetainingEnvironmentValues() throws {
    let secret = "super-secret-value"
    let rendered = renderedConfiguration(
      full: """
        {
          "name": "demo",
          "services": {
            "web": {
              "build": {"context": "."},
              "healthcheck": {"test": ["CMD", "true"]},
              "environment": {"TOKEN": "\(secret)"},
              "volumes": [{"type": "bind", "source": "/tmp", "target": "/data"}],
              "networks": {"default": {"aliases": ["private-alias"]}}
            }
          },
          "networks": {"default": {"name": "demo_default", "external": false}}
        }
        """,
      active: """
        {
          "name": "demo",
          "services": {
            "web": {
              "build": {"context": "."},
              "healthcheck": {"test": ["CMD", "true"]},
              "environment": {"TOKEN": "\(secret)"},
              "volumes": [{"type": "bind", "source": "/tmp", "target": "/data"}],
              "networks": {"default": {"aliases": ["private-alias"]}}
            }
          },
          "networks": {"default": {"name": "demo_default", "external": false}}
        }
        """
    )

    let review = try decoder.decode(rendered: rendered, expectedProjectName: "demo")
    let messages = review.issues.map(\.message).joined(separator: " ")

    #expect(review.issues.count >= 4)
    #expect(review.issues.allSatisfy { $0.severity == .blocker })
    #expect(!messages.contains(secret))
    #expect(review.desiredState.activeServices.first?.imageReference == "")
  }

  @Test
  func blocksCanonicalKeysOutsideTheExplicitExecutionAllowlist() throws {
    let rendered = renderedConfiguration(
      full: """
        {
          "name": "demo",
          "services": {
            "web": {
              "image": "nginx:1.27",
              "read_only": true,
              "ports": [{"target": 80, "published": "8080", "mode": "host"}]
            }
          },
          "volumes": {
            "data": {"name": "demo_data", "labels": {"private": "redacted"}}
          }
        }
        """,
      active: """
        {
          "name": "demo",
          "services": {
            "web": {
              "image": "nginx:1.27",
              "read_only": true,
              "ports": [{"target": 80, "published": "8080", "mode": "host"}]
            }
          },
          "volumes": {
            "data": {"name": "demo_data", "labels": {"private": "redacted"}}
          }
        }
        """
    )

    let review = try decoder.decode(rendered: rendered, expectedProjectName: "demo")
    let messages = review.issues.map(\.message)

    #expect(messages.contains { $0.contains("unsupported key read_only") })
    #expect(messages.contains("Only ingress-mode published ports are supported."))
    #expect(messages.contains { $0.contains("Custom volume labels") })
    #expect(!messages.joined().contains("redacted"))
  }

  @Test
  func derivesReplicaCountAndRejectsContainerNameScaling() throws {
    let rendered = renderedConfiguration(
      full: """
        {"name":"demo","services":{"api":{"image":"example/api","scale":2,"container_name":"fixed"}}}
        """,
      active: """
        {"name":"demo","services":{"api":{"image":"example/api","scale":2,"container_name":"fixed"}}}
        """
    )

    let review = try decoder.decode(rendered: rendered, expectedProjectName: "demo")

    #expect(review.desiredState.activeServices.first?.replicaCount == 2)
    #expect(review.issues.contains { $0.code == .invalidModel })
  }

  @Test
  func retainsSupportedDependencyOrderAndBlocksCycles() throws {
    let acyclic = renderedConfiguration(
      full: """
        {
          "name":"demo",
          "services":{
            "database":{"image":"postgres:17"},
            "web":{"image":"example/web","depends_on":{"database":{"condition":"service_started","required":true,"restart":false}}}
          }
        }
        """,
      active: """
        {
          "name":"demo",
          "services":{
            "database":{"image":"postgres:17"},
            "web":{"image":"example/web","depends_on":{"database":{"condition":"service_started","required":true,"restart":false}}}
          }
        }
        """
    )
    let acyclicReview = try decoder.decode(rendered: acyclic, expectedProjectName: "demo")
    #expect(acyclicReview.desiredState.serviceDependencies["web"] == ["database"])
    #expect(
      acyclicReview.desiredState.activeServices.first(where: { $0.name == "web" })?
        .dependencyNames == ["database"]
    )
    #expect(acyclicReview.issues.isEmpty)

    let cyclic = renderedConfiguration(
      full: """
        {"name":"demo","services":{
          "database":{"image":"postgres:17","depends_on":{"web":{"condition":"service_started"}}},
          "web":{"image":"example/web","depends_on":{"database":{"condition":"service_started"}}}
        }}
        """,
      active: """
        {"name":"demo","services":{
          "database":{"image":"postgres:17","depends_on":{"web":{"condition":"service_started"}}},
          "web":{"image":"example/web","depends_on":{"database":{"condition":"service_started"}}}
        }}
        """
    )
    let cyclicReview = try decoder.decode(rendered: cyclic, expectedProjectName: "demo")
    #expect(
      cyclicReview.issues.count(where: {
        $0.code == .invalidModel && $0.message.contains("cycle")
      }) == 2
    )
  }

  private func renderedConfiguration(
    full: String,
    active: String
  ) -> ComposeRenderedConfiguration {
    let object = try! JSONSerialization.jsonObject(with: Data(full.utf8)) as! [String: Any]
    let services = object["services"] as! [String: Any]
    let hashes = Dictionary(
      uniqueKeysWithValues: services.keys.map {
        ($0, String(repeating: $0 == "web" ? "a" : "b", count: 64))
      }
    )
    return ComposeRenderedConfiguration(
      fullConfiguration: Data(full.utf8),
      activeConfiguration: Data(active.utf8),
      fullConfigurationSHA256: String(repeating: "a", count: 64),
      activeConfigurationSHA256: String(repeating: "b", count: 64),
      composeReleaseVersion: DockerComposeRelease.pinned.version,
      composeBinarySHA256: DockerComposeRelease.pinned.binarySHA256,
      composeSourceRevision: DockerComposeRelease.pinned.sourceRevision,
      environmentSHA256: String(repeating: "c", count: 64),
      serviceConfigurationHashes: hashes
    )
  }
}

private actor ComposeCommandExecutorDouble: HostCommandExecuting {
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
      return HostCommandResult(
        exitCode: 99,
        standardOutput: "",
        standardError: "",
        outputWasTruncated: false
      )
    }
    return results.removeFirst()
  }
}

private actor ReadyComposeClientDouble: DockerComposeClientInstalling {
  nonisolated let release = DockerComposeRelease.pinned
  nonisolated let executableURL = URL(filePath: "/private/docker-compose")
  nonisolated let provenanceURL = URL(filePath: "/private/provenance.json")

  func snapshot() async -> DockerComposeClientSnapshot {
    DockerComposeClientSnapshot(
      release: release,
      installation: .ready(version: release.version),
      executableURL: executableURL,
      provenanceURL: provenanceURL
    )
  }

  func installationState() async -> DockerComposeClientInstallationState {
    .ready(version: release.version)
  }

  func verifiedExecutableURL() async throws -> URL {
    executableURL
  }

  func install() async throws {}
}

extension Array where Element == String {
  fileprivate func containsSubsequence(_ values: [String]) -> Bool {
    guard !values.isEmpty, values.count <= count else { return false }
    return indices.contains { start in
      let end = index(start, offsetBy: values.count, limitedBy: endIndex) ?? endIndex
      return end - start == values.count && Array(self[start..<end]) == values
    }
  }
}
