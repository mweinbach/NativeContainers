import ContainerResource
import Foundation

protocol ContainerShellConfigurationLoading: Sendable {
  func loadShellConfiguration(in containerID: String) async throws -> ProcessConfiguration
}

struct AppleContainerShellConfigurationLoader: ContainerShellConfigurationLoading {
  private let snapshotReader: any ContainerSnapshotReading

  init(snapshotReader: any ContainerSnapshotReading = AppleContainerSnapshotReader()) {
    self.snapshotReader = snapshotReader
  }

  func loadShellConfiguration(in containerID: String) async throws -> ProcessConfiguration {
    let snapshot = try await snapshotReader.get(id: containerID)
    guard snapshot.status == .running else {
      throw ContainerShellDiscoveryError.containerNotRunning(containerID)
    }
    return snapshot.configuration.initProcess
  }
}

struct ContainerShellCandidatePolicy: Sendable {
  private static let knownShellNames: Set<String> = [
    "ash", "bash", "dash", "fish", "ksh", "mksh", "sh", "yash", "zsh",
  ]

  static let fallbackExecutables = [
    "/bin/bash",
    "/usr/bin/bash",
    "/bin/zsh",
    "/usr/bin/zsh",
    "/usr/bin/fish",
    "/bin/fish",
    "/bin/ash",
    "/usr/bin/ash",
    "/bin/dash",
    "/usr/bin/dash",
    "/bin/ksh",
    "/usr/bin/ksh",
    "/bin/sh",
    "/usr/bin/sh",
    "bash",
    "zsh",
    "fish",
    "ash",
    "dash",
    "ksh",
    "sh",
  ]

  func candidates(for configuration: ProcessConfiguration) -> [ContainerShell] {
    var candidates: [ContainerShell] = []
    var seenExecutables: Set<String> = []

    if let environmentShell = shellEnvironmentValue(in: configuration.environment) {
      append(
        environmentShell,
        source: .environment,
        to: &candidates,
        seenExecutables: &seenExecutables
      )
    }

    if Self.knownShellNames.contains(
      URL(filePath: configuration.executable).lastPathComponent.lowercased()
    ) {
      append(
        configuration.executable,
        source: .containerProcess,
        to: &candidates,
        seenExecutables: &seenExecutables
      )
    }

    for executable in Self.fallbackExecutables {
      append(
        executable,
        source: .fallback,
        to: &candidates,
        seenExecutables: &seenExecutables
      )
    }
    return candidates
  }

  private func shellEnvironmentValue(in environment: [String]) -> String? {
    environment.reversed().compactMap { entry in
      let pair = entry.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
      guard pair.count == 2, pair[0] == "SHELL" else { return nil }
      return String(pair[1])
    }.first
  }

  private func append(
    _ executable: String,
    source: ContainerShellSource,
    to candidates: inout [ContainerShell],
    seenExecutables: inout Set<String>
  ) {
    let executable = executable.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !executable.isEmpty, seenExecutables.insert(executable).inserted else { return }
    candidates.append(ContainerShell(executable: executable, source: source))
  }
}

actor AppleContainerShellService: ContainerShellDiscovering {
  private static let probeTimeoutSeconds = 1

  private let configurationLoader: any ContainerShellConfigurationLoading
  private let commandExecutor: any RuntimeCommandExecuting
  private let candidatePolicy: ContainerShellCandidatePolicy

  init(
    configurationLoader: any ContainerShellConfigurationLoading =
      AppleContainerShellConfigurationLoader(),
    commandExecutor: any RuntimeCommandExecuting = AppleRuntimeCommandExecutor(),
    candidatePolicy: ContainerShellCandidatePolicy = ContainerShellCandidatePolicy()
  ) {
    self.configurationLoader = configurationLoader
    self.commandExecutor = commandExecutor
    self.candidatePolicy = candidatePolicy
  }

  func discoverShell(in id: String) async throws -> ContainerShell {
    let id = id.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !id.isEmpty else {
      throw ContainerShellDiscoveryError.invalidContainerIdentifier
    }

    let baseConfiguration = try await configurationLoader.loadShellConfiguration(in: id)
    for candidate in candidatePolicy.candidates(for: baseConfiguration) {
      try Task.checkCancellation()
      var probeConfiguration = baseConfiguration
      probeConfiguration.executable = candidate.executable
      probeConfiguration.arguments = ["-c", "exit 0"]
      probeConfiguration.terminal = false

      do {
        let result = try await commandExecutor.execute(
          in: id,
          configuration: probeConfiguration,
          timeoutSeconds: Self.probeTimeoutSeconds
        )
        if result.exitCode == 0 {
          return candidate
        }
      } catch is CancellationError {
        throw CancellationError()
      } catch {
        continue
      }
    }

    throw ContainerShellDiscoveryError.unavailable(id)
  }
}
