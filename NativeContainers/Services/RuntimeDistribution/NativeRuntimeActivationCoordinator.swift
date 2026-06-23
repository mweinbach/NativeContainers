import Foundation

protocol NativeRuntimeLaunchGraphSnapshotting: Sendable {
  func snapshot() async throws -> [NativeRuntimeLaunchServiceObservation]
}

protocol NativeRuntimeGraphControlling: Sendable {
  func start(_ origin: NativeRuntimeOrigin) async throws
  func stop(_ origin: NativeRuntimeOrigin) async throws
}

struct NativeRuntimeLaunchGraphClassifier: Sendable {
  private let contractsByOrigin: [NativeRuntimeOrigin: NativeRuntimeLaunchGraphContract]

  init(manifests: [NativeRuntimeDistributionManifest]) {
    self.init(
      servicesByOrigin: Dictionary(
        uniqueKeysWithValues: manifests.map { ($0.origin, $0.launchServices) }
      )
    )
  }

  init(
    servicesByOrigin: [NativeRuntimeOrigin: [NativeRuntimeLaunchServiceContract]]
  ) {
    self.init(
      contractsByOrigin: servicesByOrigin.mapValues(Self.inferredContract)
    )
  }

  init(
    contractsByOrigin: [NativeRuntimeOrigin: NativeRuntimeLaunchGraphContract]
  ) {
    self.contractsByOrigin = contractsByOrigin
  }

  func classify(
    _ observations: [NativeRuntimeLaunchServiceObservation]
  ) throws -> NativeRuntimeLaunchGraphState {
    guard !observations.isEmpty else { return .inactive }

    var seen = Set<String>()
    var observedOrigins = Set<NativeRuntimeOrigin>()
    for observation in observations {
      let key = "\(observation.domain)/\(observation.label)"
      guard seen.insert(key).inserted else {
        throw NativeRuntimeLaunchGraphError.duplicateService(key)
      }

      let matches = contractsByOrigin.compactMap {
        origin,
        contract -> NativeRuntimeOrigin? in
        guard
          contract.services.contains(where: {
            $0.label == observation.label
              && $0.domain == observation.domain
              && Self.samePath($0.executableURL, observation.executableURL)
          })
        else {
          return nil
        }
        return origin
      }
      guard matches.count == 1, let origin = matches.first else {
        throw NativeRuntimeLaunchGraphError.unknownOwner(
          label: key,
          executable: observation.executableURL.path
        )
      }
      observedOrigins.insert(origin)
    }

    guard observedOrigins.count == 1, let origin = observedOrigins.first else {
      throw NativeRuntimeLaunchGraphError.mixedOwners
    }
    guard
      let contract = contractsByOrigin[origin],
      contract.requiredServiceKeys.isSubset(of: seen)
    else {
      throw NativeRuntimeLaunchGraphError.incompleteGraph(origin)
    }
    return .active(origin)
  }

  private static func inferredContract(
    services: [NativeRuntimeLaunchServiceContract]
  ) -> NativeRuntimeLaunchGraphContract {
    let anchors = services.filter {
      $0.label == "com.apple.container.apiserver"
    }
    return NativeRuntimeLaunchGraphContract(
      services: services,
      requiredServices: anchors.isEmpty ? services : anchors
    )
  }

  private static func samePath(_ lhs: URL, _ rhs: URL) -> Bool {
    lhs.standardizedFileURL.path(percentEncoded: false)
      == rhs.standardizedFileURL.path(percentEncoded: false)
  }
}

struct LaunchctlNativeRuntimeGraphSnapshotter:
  NativeRuntimeLaunchGraphSnapshotting
{
  private let contracts: [NativeRuntimeLaunchServiceContract]
  private let commandExecutor: any HostCommandExecuting

  init(
    manifests: [NativeRuntimeDistributionManifest],
    commandExecutor: any HostCommandExecuting = FoundationHostCommandExecutor()
  ) {
    self.init(
      contracts: manifests.flatMap(\.launchServices),
      commandExecutor: commandExecutor
    )
  }

  init(
    servicesByOrigin: [NativeRuntimeOrigin: [NativeRuntimeLaunchServiceContract]],
    commandExecutor: any HostCommandExecuting = FoundationHostCommandExecutor()
  ) {
    self.init(
      contracts: servicesByOrigin.values.flatMap { $0 },
      commandExecutor: commandExecutor
    )
  }

  private init(
    contracts: [NativeRuntimeLaunchServiceContract],
    commandExecutor: any HostCommandExecuting
  ) {
    var unique: [String: NativeRuntimeLaunchServiceContract] = [:]
    for service in contracts {
      unique["\(service.domain)/\(service.label)"] = service
    }
    self.contracts = unique.values.sorted {
      ("\($0.domain)/\($0.label)") < ("\($1.domain)/\($1.label)")
    }
    self.commandExecutor = commandExecutor
  }

  func snapshot() async throws -> [NativeRuntimeLaunchServiceObservation] {
    var observations: [NativeRuntimeLaunchServiceObservation] = []
    for contract in contracts {
      let result: HostCommandResult
      do {
        result = try await commandExecutor.execute(
          executableURL: URL(filePath: "/bin/launchctl"),
          arguments: ["print", "\(contract.domain)/\(contract.label)"],
          environment: nil,
          timeout: .seconds(10)
        )
      } catch {
        throw NativeRuntimeLaunchGraphError.inspectionFailed(
          error.localizedDescription
        )
      }
      if result.exitCode != 0 {
        continue
      }
      guard let program = Self.programPath(in: result.standardOutput) else {
        throw NativeRuntimeLaunchGraphError.inspectionFailed(
          "launchctl did not report the program for \(contract.label)."
        )
      }
      observations.append(
        NativeRuntimeLaunchServiceObservation(
          label: contract.label,
          domain: contract.domain,
          executableURL: URL(filePath: program)
        )
      )
    }
    return observations
  }

  static func programPath(in output: String) -> String? {
    for line in output.split(separator: "\n") {
      let trimmed = line.trimmingCharacters(in: .whitespaces)
      guard trimmed.hasPrefix("program =") else { continue }
      let value = trimmed.dropFirst("program =".count)
        .trimmingCharacters(in: .whitespaces)
      if value.hasPrefix("\""), value.hasSuffix("\""), value.count >= 2 {
        return String(value.dropFirst().dropLast())
      }
      return value.isEmpty ? nil : value
    }
    return nil
  }
}

actor CommandNativeRuntimeGraphController: NativeRuntimeGraphControlling {
  private let commands: [NativeRuntimeOrigin: NativeRuntimeControlCommand]
  private let commandExecutor: any HostCommandExecuting

  init(
    commands: [NativeRuntimeOrigin: NativeRuntimeControlCommand],
    commandExecutor: any HostCommandExecuting = FoundationHostCommandExecutor()
  ) {
    self.commands = commands
    self.commandExecutor = commandExecutor
  }

  func start(_ origin: NativeRuntimeOrigin) async throws {
    try await execute(origin: origin, operation: "start")
  }

  func stop(_ origin: NativeRuntimeOrigin) async throws {
    try await execute(origin: origin, operation: "stop")
  }

  private func execute(
    origin: NativeRuntimeOrigin,
    operation: String
  ) async throws {
    guard let command = commands[origin] else {
      throw NativeRuntimeActivationError.commandFailed(
        origin: origin,
        operation: operation,
        detail: "No reviewed command is configured."
      )
    }
    let arguments =
      operation == "start"
      ? command.startArguments
      : command.stopArguments
    let result: HostCommandResult
    do {
      result = try await commandExecutor.execute(
        executableURL: command.executableURL,
        arguments: arguments,
        environment: nil,
        timeout: command.timeout
      )
    } catch {
      throw NativeRuntimeActivationError.commandFailed(
        origin: origin,
        operation: operation,
        detail: error.localizedDescription
      )
    }
    guard result.exitCode == 0 else {
      throw NativeRuntimeActivationError.commandFailed(
        origin: origin,
        operation: operation,
        detail: Self.detail(result)
      )
    }
  }

  private nonisolated static func detail(_ result: HostCommandResult) -> String {
    let output = [result.standardError, result.standardOutput]
      .filter { !$0.isEmpty }
      .joined(separator: "\n")
      .trimmingCharacters(in: .whitespacesAndNewlines)
    let suffix = String(output.suffix(2_000))
    return suffix.isEmpty ? "Exit status \(result.exitCode)." : suffix
  }
}

actor NativeRuntimeActivationCoordinator {
  private let manifests: [NativeRuntimeOrigin: NativeRuntimeDistributionManifest]
  private let distributionVerifier: any NativeRuntimeDistributionVerifying
  private let graphSnapshotter: any NativeRuntimeLaunchGraphSnapshotting
  private let graphClassifier: NativeRuntimeLaunchGraphClassifier
  private let graphController: any NativeRuntimeGraphControlling

  init(
    manifests: [NativeRuntimeDistributionManifest],
    distributionVerifier: any NativeRuntimeDistributionVerifying,
    graphSnapshotter: any NativeRuntimeLaunchGraphSnapshotting,
    graphController: any NativeRuntimeGraphControlling
  ) {
    self.manifests = Dictionary(
      uniqueKeysWithValues: manifests.map { ($0.origin, $0) }
    )
    self.distributionVerifier = distributionVerifier
    self.graphSnapshotter = graphSnapshotter
    graphClassifier = NativeRuntimeLaunchGraphClassifier(manifests: manifests)
    self.graphController = graphController
  }

  func activate(_ target: NativeRuntimeOrigin) async throws {
    guard let targetManifest = manifests[target] else {
      throw NativeRuntimeActivationError.activationFailed(
        "The target distribution is not configured."
      )
    }
    _ = try await distributionVerifier.verify(targetManifest)

    let initial = try await currentState()
    switch initial {
    case .active(let active) where active == target:
      return
    case .inactive:
      try await startAndVerify(target)
    case .active(let source):
      guard let sourceManifest = manifests[source] else {
        throw NativeRuntimeActivationError.activationFailed(
          "The active distribution is not configured for rollback."
        )
      }
      _ = try await distributionVerifier.verify(sourceManifest)

      try await graphController.stop(source)
      do {
        guard try await currentState() == .inactive else {
          throw NativeRuntimeActivationError.graphDidNotStop(source)
        }
        try await startAndVerify(target)
      } catch {
        let activationDetail = error.localizedDescription
        do {
          try await rollback(from: target, to: source, manifest: sourceManifest)
        } catch {
          throw NativeRuntimeActivationError.rollbackFailed(
            activation: activationDetail,
            rollback: error.localizedDescription
          )
        }
        throw NativeRuntimeActivationError.activationFailed(activationDetail)
      }
    }
  }

  private func startAndVerify(_ origin: NativeRuntimeOrigin) async throws {
    try await graphController.start(origin)
    guard try await currentState() == .active(origin) else {
      throw NativeRuntimeActivationError.graphDidNotStart(origin)
    }
  }

  private func rollback(
    from target: NativeRuntimeOrigin,
    to source: NativeRuntimeOrigin,
    manifest: NativeRuntimeDistributionManifest
  ) async throws {
    try await graphController.stop(target)
    guard try await currentState() == .inactive else {
      throw NativeRuntimeActivationError.graphDidNotStop(target)
    }
    _ = try await distributionVerifier.verify(manifest)
    try await graphController.start(source)
    guard try await currentState() == .active(source) else {
      throw NativeRuntimeActivationError.graphDidNotStart(source)
    }
  }

  private func currentState() async throws -> NativeRuntimeLaunchGraphState {
    let observations = try await graphSnapshotter.snapshot()
    return try graphClassifier.classify(observations)
  }
}

protocol ActiveNativeRuntimeVerifying: Sendable {
  func verifyActiveNativeRuntime() async throws -> NativeRuntimeVerifiedDistribution
}

actor ActiveNativeRuntimeVerifier: ActiveNativeRuntimeVerifying {
  private let nativeManifest: NativeRuntimeDistributionManifest
  private let distributionVerifier: any NativeRuntimeDistributionVerifying
  private let graphSnapshotter: any NativeRuntimeLaunchGraphSnapshotting
  private let graphClassifier: NativeRuntimeLaunchGraphClassifier

  init(
    nativeManifest: NativeRuntimeDistributionManifest,
    allManifests: [NativeRuntimeDistributionManifest],
    distributionVerifier: any NativeRuntimeDistributionVerifying,
    graphSnapshotter: any NativeRuntimeLaunchGraphSnapshotting
  ) {
    self.nativeManifest = nativeManifest
    self.distributionVerifier = distributionVerifier
    self.graphSnapshotter = graphSnapshotter
    graphClassifier = NativeRuntimeLaunchGraphClassifier(manifests: allManifests)
  }

  func verifyActiveNativeRuntime() async throws -> NativeRuntimeVerifiedDistribution {
    guard
      nativeManifest.origin == .nativeContainers,
      nativeManifest.teamIdentifier
        == NativeRuntimeDistributionManifest.nativeContainersTeamIdentifier,
      nativeManifest.builderArtifact == .pinned
    else {
      throw NativeRuntimeDistributionError.invalidManifest(
        "The active NativeContainers contract is not the pinned release."
      )
    }

    let verified = try await distributionVerifier.verify(nativeManifest)
    let state = try graphClassifier.classify(
      try await graphSnapshotter.snapshot()
    )
    guard state == .active(.nativeContainers) else {
      throw NativeRuntimeActivationError.graphDidNotStart(.nativeContainers)
    }
    return verified
  }
}
