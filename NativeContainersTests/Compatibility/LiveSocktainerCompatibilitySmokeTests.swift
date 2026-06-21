import Darwin
import Foundation
import Testing

@testable import NativeContainers

@Suite(.serialized)
struct LiveSocktainerCompatibilitySmokeTests {
  @Test(
    .enabled(
      if: ProcessInfo.processInfo.environment[
        "NATIVECONTAINERS_LIVE_SOCKTAINER"
      ] == "1",
      "Set NATIVECONTAINERS_LIVE_SOCKTAINER=1 with Apple container 1.0.0 running, Docker installed, the verified private Compose client installed, and the pinned bridge binary available."
    )
  )
  func validatedBridgeServesIsolatedDockerContextAndCleansUp() async throws {
    let environment = ProcessInfo.processInfo.environment
    let binaryURL = URL(
      filePath:
        environment["NATIVECONTAINERS_SOCKTAINER_BINARY"]
        ?? "/tmp/nativecontainers-socktainer-v1.0.0"
    )
    try SocktainerArtifactValidator().validate(
      artifactURL: binaryURL,
      release: .pinned
    )

    #expect(
      await AppleContainerHealthVersionChecker().compatibility(requiredVersion: "1.0.0")
        == .compatible(version: "1.0.0")
    )

    let rootURL = URL(filePath: "/tmp", directoryHint: .isDirectory).appending(
      path: "nc-st-\(UUID().uuidString.lowercased().prefix(8))",
      directoryHint: .isDirectory
    )
    try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: false)
    defer { try? FileManager.default.removeItem(at: rootURL) }

    let socketURL =
      rootURL
      .appending(path: ".socktainer", directoryHint: .isDirectory)
      .appending(path: "container.sock", directoryHint: .notDirectory)
    var isolatedEnvironment = environment
    isolatedEnvironment["HOME"] = rootURL.nativeContainersPOSIXPath
    isolatedEnvironment["DOCKER_CONFIG"] =
      rootURL
      .appending(path: ".docker", directoryHint: .isDirectory)
      .nativeContainersPOSIXPath

    let process = SocktainerProcessService(
      socketURL: socketURL,
      environment: isolatedEnvironment,
      startupTimeout: .seconds(15)
    )
    let executor = FoundationHostCommandExecutor()
    let context = DockerContextService(
      socketURL: socketURL,
      commandExecutor: executor,
      environment: isolatedEnvironment
    )
    let dockerURL = try #require(
      FixedPathHostExecutableLocator().locate(candidates: [
        URL(filePath: "/usr/local/bin/docker"),
        URL(filePath: "/opt/homebrew/bin/docker"),
        URL(filePath: "/usr/bin/docker"),
      ])
    )

    do {
      try await process.start(executableURL: binaryURL)
      guard case .running = await process.status() else {
        Issue.record("Socktainer did not remain running after readiness.")
        try await process.forceStop()
        return
      }

      try await context.createOrRepairContext()
      #expect((await context.status()).state == .ready)

      let version = try await executor.execute(
        executableURL: dockerURL,
        arguments: [
          "--context", DockerContextService.contextName,
          "version", "--format", "{{json .Server}}",
        ],
        environment: isolatedEnvironment,
        timeout: .seconds(20)
      )
      #expect(version.exitCode == 0)
      #expect(version.standardOutput.contains("1.51"))

      let inventory = try await executor.execute(
        executableURL: dockerURL,
        arguments: [
          "--context", DockerContextService.contextName,
          "ps", "-a", "--format", "{{.ID}}",
        ],
        environment: isolatedEnvironment,
        timeout: .seconds(20)
      )
      #expect(inventory.exitCode == 0)

      try await process.stop()
      #expect(await process.status() == .stopped)
      #expect(!FileManager.default.fileExists(atPath: socketURL.nativeContainersPOSIXPath))
    } catch {
      try? await process.forceStop()
      throw error
    }
  }

  @Test(
    .enabled(
      if: ProcessInfo.processInfo.environment[
        "NATIVECONTAINERS_LIVE_SOCKTAINER"
      ] == "1",
      "Set NATIVECONTAINERS_LIVE_SOCKTAINER=1 with Apple container 1.0.0 running, Docker installed, the verified private Compose client installed, and the pinned bridge binary available."
    )
  )
  func composeFixturePublishesCanonicalAppleTopologyAndCleansUp() async throws {
    try await runComposeFixture(forceComposeDownFailure: false)
  }

  @Test(
    .enabled(
      if: ProcessInfo.processInfo.environment[
        "NATIVECONTAINERS_LIVE_SOCKTAINER"
      ] == "1",
      "Set NATIVECONTAINERS_LIVE_SOCKTAINER=1 with Apple container 1.0.0 running, Docker installed, the verified private Compose client installed, and the pinned bridge binary available."
    )
  )
  func failedComposeDownUsesAppleNativeForceCleanup() async throws {
    try await runComposeFixture(forceComposeDownFailure: true)
  }

  private func runComposeFixture(
    forceComposeDownFailure: Bool
  ) async throws {
    let environment = ProcessInfo.processInfo.environment
    let binaryURL = URL(
      filePath:
        environment["NATIVECONTAINERS_SOCKTAINER_BINARY"]
        ?? "/tmp/nativecontainers-socktainer-v1.0.0"
    )
    try SocktainerArtifactValidator().validate(
      artifactURL: binaryURL,
      release: .pinned
    )
    #expect(
      await AppleContainerHealthVersionChecker().compatibility(requiredVersion: "1.0.0")
        == .compatible(version: "1.0.0")
    )

    let rootURL = URL(filePath: "/tmp", directoryHint: .isDirectory).appending(
      path: "nc-sc-\(UUID().uuidString.lowercased().prefix(8))",
      directoryHint: .isDirectory
    )
    try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: false)
    defer { try? FileManager.default.removeItem(at: rootURL) }

    let socketURL =
      rootURL
      .appending(path: ".socktainer", directoryHint: .isDirectory)
      .appending(path: "container.sock", directoryHint: .notDirectory)
    var isolatedEnvironment = environment
    isolatedEnvironment["HOME"] = rootURL.nativeContainersPOSIXPath
    isolatedEnvironment["DOCKER_CONFIG"] =
      rootURL
      .appending(path: ".docker", directoryHint: .isDirectory)
      .nativeContainersPOSIXPath

    let process = SocktainerProcessService(
      socketURL: socketURL,
      environment: isolatedEnvironment,
      startupTimeout: .seconds(15)
    )
    let executor = FoundationHostCommandExecutor()
    let context = DockerContextService(
      socketURL: socketURL,
      commandExecutor: executor,
      environment: isolatedEnvironment
    )
    let composeClient = DockerComposeClientInstallService()
    let installedComposeURL = try await composeClient.verifiedExecutableURL()
    let composeURL: URL
    if forceComposeDownFailure {
      composeURL = rootURL.appending(
        path: "docker-compose-failing-down",
        directoryHint: .notDirectory
      )
      let quotedExecutable = installedComposeURL.nativeContainersPOSIXPath
        .replacingOccurrences(of: "'", with: "'\"'\"'")
      let wrapper = """
        #!/bin/sh
        for argument in "$@"; do
          if [ "$argument" = "down" ]; then
            echo "intentional live teardown failure" >&2
            exit 17
          fi
        done
        exec '\(quotedExecutable)' "$@"
        """
      try wrapper.write(to: composeURL, atomically: true, encoding: .utf8)
      guard chmod(composeURL.nativeContainersPOSIXPath, 0o700) == 0 else {
        throw CocoaError(.fileWriteNoPermission)
      }
    } else {
      composeURL = installedComposeURL
    }

    do {
      try await process.start(executableURL: binaryURL)
      guard case .running = await process.status() else {
        Issue.record("Socktainer did not remain running after readiness.")
        try await process.forceStop()
        return
      }
      try await context.createOrRepairContext()

      let projectName = "ncwire-\(UUID().uuidString.lowercased().prefix(8))"
      let fixture = SocktainerComposeLiveConformanceService(
        commandExecutor: executor,
        inventory: AppleRuntimeInventoryService()
      )
      let result = try await fixture.run(
        configuration: try SocktainerComposeLiveFixtureConfiguration(
          projectName: projectName,
          workspaceURL: rootURL,
          composeExecutableURL: composeURL,
          environment: isolatedEnvironment
        )
      )

      #expect(result.projectName == projectName)
      #expect(result.observedState == .allRunning)
      #expect(result.containerID == "\(projectName)-probe")
      #expect(result.usedFallbackCleanup == forceComposeDownFailure)

      try await process.stop()
      #expect(await process.status() == .stopped)
      #expect(!FileManager.default.fileExists(atPath: socketURL.nativeContainersPOSIXPath))
    } catch {
      try? await process.forceStop()
      throw error
    }
  }
}
