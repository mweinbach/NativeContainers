import ContainerAPIClient
import ContainerBuild
import ContainerPersistence
import ContainerResource
import Containerization
import ContainerizationError
import ContainerizationOCI
import Foundation
import Logging
import SystemPackage
import TerminalProgress

struct ReviewedContainerBuilder: Sendable {
  let systemConfiguration: ContainerSystemConfig
  fileprivate let acceptedSnapshot: ContainerSnapshot
}

struct ContainerBuilderController {
  static let vsockPort: UInt32 = 8_088
  static let resourceDirectoryName = "builder"

  private let client = ContainerClient()
  private let writer: ContainerBuildWorkerEventWriter
  private let logger = Logger(label: "com.nativecontainers.build-worker")

  private struct ResolvedConfiguration {
    let system: ContainerSystemConfig
    let resources: ContainerConfiguration.Resources
    let managedEnvironment: [String]
    let useRosetta: Bool
    let exportsRoot: URL
    let builtinNetworkID: String

    var processArguments: [String] {
      ["--debug", "--vsock", useRosetta ? nil : "--enable-qemu"].compactMap { $0 }
    }

    var builderDNS: ContainerBuilderDNSConfiguration {
      ContainerBuilderDNSConfiguration(
        nameservers: [],
        domain: nil,
        searchDomains: [],
        options: []
      )
    }
  }

  init(writer: ContainerBuildWorkerEventWriter) {
    self.writer = writer
  }

  func ensureBuilder(
    requested: ContainerBuilderConfiguration
  ) async throws -> ReviewedContainerBuilder {
    let resolved = try await resolve(requested)
    let builderImage = try await resolveBuilderImage(resolved)
    let existing = try await existingBuilder()
    let decision = safetyDecision(
      existing: existing,
      resolved: resolved,
      imageDescriptorDigest: builderImage.descriptor.digest,
      requested: requested
    )
    guard let action = decision.action else {
      throw safetyError(decision)
    }
    switch action {
    case .create:
      try await createBuilder(resolved, image: builderImage)
    case .reuse:
      break
    case .start:
      guard let existing else { preconditionFailure("Start requires an existing builder") }
      _ = try await requireUnchangedBuilder(existing, allowedStates: [.stopped])
      try await emit("Starting existing Apple BuildKit container")
      try await startBuilderProcess(id: Builder.builderContainerId)
    case .stopDeleteCreate:
      guard let existing else { preconditionFailure("Recreate requires an existing builder") }
      _ = try await requireUnchangedBuilder(existing, allowedStates: [.running])
      try await emit("Stopping and recreating the shared Apple BuildKit container")
      try await client.stop(id: Builder.builderContainerId)
      _ = try await requireUnchangedBuilder(existing, allowedStates: [.stopped])
      try await client.delete(id: Builder.builderContainerId)
      try await createBuilder(resolved, image: builderImage)
    case .deleteCreate:
      guard let existing else { preconditionFailure("Recreate requires an existing builder") }
      _ = try await requireUnchangedBuilder(existing, allowedStates: [.stopped])
      try await emit("Recreating the stopped Apple BuildKit container")
      try await client.delete(id: Builder.builderContainerId)
      try await createBuilder(resolved, image: builderImage)
    }
    return try await requireRunningBuilder(
      resolved: resolved,
      imageDescriptorDigest: builderImage.descriptor.digest
    )
  }

  func requireRunningBuilder(
    requested: ContainerBuilderConfiguration
  ) async throws -> ReviewedContainerBuilder {
    let resolved = try await resolve(requested)
    let builderImage = try await resolveBuilderImage(resolved)
    return try await requireRunningBuilder(
      resolved: resolved,
      imageDescriptorDigest: builderImage.descriptor.digest
    )
  }

  private func requireRunningBuilder(
    resolved: ResolvedConfiguration,
    imageDescriptorDigest: String
  ) async throws -> ReviewedContainerBuilder {
    let existing = try await existingBuilder()
    let decision = safetyDecision(
      existing: existing,
      resolved: resolved,
      imageDescriptorDigest: imageDescriptorDigest,
      requested: .default
    )
    guard decision.action == .reuse else {
      if decision.action == .create || decision.action == .start {
        throw ContainerBuildWorkerError.make(
          code: "builder-not-running",
          message: "Apple’s BuildKit container stopped after preparation. Prepare it again."
        )
      }
      throw safetyError(decision)
    }
    guard decision.isAllowed else {
      throw ContainerBuildWorkerError.make(
        code: "builder-not-running",
        message: "Apple’s BuildKit container is not ready. Prepare it again."
      )
    }
    guard let existing else {
      throw ContainerBuildWorkerError.make(
        code: "builder-not-running",
        message: "Apple’s BuildKit container disappeared after review. Prepare it again."
      )
    }
    return ReviewedContainerBuilder(
      systemConfiguration: resolved.system,
      acceptedSnapshot: existing
    )
  }

  func waitUntilDialable(timeout: Duration = .seconds(60)) async throws -> FileHandle {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: timeout)
    var lastError: (any Error)?
    while clock.now < deadline {
      try Task.checkCancellation()
      do {
        return try await client.dial(id: Builder.builderContainerId, port: Self.vsockPort)
      } catch {
        lastError = error
        try await Task.sleep(for: .milliseconds(250))
      }
    }
    throw ContainerBuildWorkerError.make(
      code: "builder-timeout",
      message:
        "Timed out waiting for Apple’s BuildKit service: \(lastError?.localizedDescription ?? "no connection")"
    )
  }

  func dialReviewedBuilder(
    _ reviewed: ReviewedContainerBuilder,
    timeout: Duration = .seconds(60)
  ) async throws -> FileHandle {
    do {
      return try await ContainerBuilderDialGate.connect(
        expected: reviewedSnapshot(reviewed.acceptedSnapshot),
        current: {
          guard let current = try await existingBuilder() else { return nil }
          return reviewedSnapshot(current)
        },
        dial: {
          try await waitUntilDialable(timeout: timeout)
        },
        close: { socket in
          try? socket.close()
        }
      )
    } catch let error as ContainerBuilderDialGateError {
      let timing =
        switch error {
        case .changedBeforeDial: "before connecting"
        case .changedAfterDial: "while connecting"
        }
      throw ContainerBuildWorkerError.make(
        code: "builder-changed",
        message:
          "Apple’s shared BuildKit container changed \(timing). NativeContainers did not use the unreviewed connection."
      )
    }
  }

  private func resolveBuilderImage(
    _ resolved: ResolvedConfiguration
  ) async throws -> ClientImage {
    try await emit("Resolving Apple’s BuildKit image")
    let image = try await ClientImage.fetch(
      reference: resolved.system.build.image,
      platform: Platform(from: "linux/arm64/v8"),
      containerSystemConfig: resolved.system,
      progressUpdate: progressHandler(phase: .preparingBuilder)
    )
    try Task.checkCancellation()
    return image
  }

  private func createBuilder(
    _ resolved: ResolvedConfiguration,
    image: ClientImage
  ) async throws {
    let progress = progressHandler(phase: .preparingBuilder)
    try FileManager.default.createDirectory(
      at: resolved.exportsRoot,
      withIntermediateDirectories: true
    )

    let platform = try Platform(from: "linux/arm64/v8")
    try await emit("Preparing Apple’s BuildKit image snapshot")
    _ = try await image.getCreateSnapshot(platform: platform, progressUpdate: progress)

    let imageConfiguration = try await image.config(for: platform).config
    var environment = imageConfiguration?.env ?? []
    environment.removeAll {
      $0.hasPrefix("BUILDKIT_COLORS=") || $0.hasPrefix("NO_COLOR=")
    }
    environment.append(contentsOf: resolved.managedEnvironment)

    let process = ProcessConfiguration(
      executable: "/usr/local/bin/container-builder-shim",
      arguments: resolved.processArguments,
      environment: environment,
      workingDirectory: "/",
      terminal: false,
      user: .id(uid: 0, gid: 0)
    )
    var configuration = ContainerConfiguration(
      id: Builder.builderContainerId,
      image: ImageDescription(
        reference: resolved.system.build.image,
        descriptor: image.descriptor
      ),
      process: process
    )
    configuration.resources = resolved.resources
    configuration.labels = [
      ResourceLabelKeys.plugin: "builder",
      ResourceLabelKeys.role: ResourceRoleValues.builder,
    ]
    configuration.capAdd = ["ALL"]
    configuration.mounts = [
      .init(type: .tmpfs, source: "", destination: "/run", options: []),
      .init(
        type: .virtiofs,
        source: resolved.exportsRoot.path(percentEncoded: false),
        destination: "/var/lib/container-builder-shim/exports",
        options: []
      ),
    ]
    configuration.rosetta = resolved.useRosetta
    configuration.networks = [
      AttachmentConfiguration(
        network: resolved.builtinNetworkID,
        options: AttachmentOptions(hostname: Builder.builderContainerId)
      )
    ]
    configuration.dns = .init(
      nameservers: resolved.builderDNS.nameservers,
      domain: resolved.builderDNS.domain,
      searchDomains: resolved.builderDNS.searchDomains,
      options: resolved.builderDNS.options
    )

    try await emit("Fetching the Apple container kernel")
    let kernel = try await ClientKernel.getDefaultKernel(for: .current)
    try Task.checkCancellation()
    try await emit("Creating Apple’s BuildKit container")
    try await client.create(
      configuration: configuration,
      options: .default,
      kernel: kernel
    )
    guard let created = try await existingBuilder() else {
      throw ContainerBuildWorkerError.make(
        code: "builder-create-lost",
        message: "Apple’s BuildKit container disappeared immediately after creation."
      )
    }
    let createdDecision = safetyDecision(
      existing: created,
      resolved: resolved,
      imageDescriptorDigest: image.descriptor.digest,
      requested: .default
    )
    guard createdDecision.action == .start else {
      throw safetyError(createdDecision)
    }
    do {
      _ = try await requireUnchangedBuilder(created, allowedStates: [.stopped])
      try await startBuilderProcess(id: Builder.builderContainerId)
    } catch {
      await cleanUpFailedBuilder(created)
      throw error
    }
  }

  private func startBuilderProcess(id: String) async throws {
    let io = try ProcessIO.create(tty: false, interactive: false, detach: true)
    defer { try? io.close() }
    var dynamicEnvironment: [String: String] = [:]
    if let socket = ProcessInfo.processInfo.environment["SSH_AUTH_SOCK"] {
      dynamicEnvironment["SSH_AUTH_SOCK"] = socket
    }
    let process = try await client.bootstrap(
      id: id,
      stdio: io.stdio,
      dynamicEnv: dynamicEnvironment
    )
    try await process.start()
    try io.closeAfterStart()
  }

  private func existingBuilder() async throws -> ContainerSnapshot? {
    do {
      return try await client.get(id: Builder.builderContainerId)
    } catch let error as ContainerizationError where error.isCode(.notFound) {
      return nil
    }
  }

  private func requireUnchangedBuilder(
    _ expected: ContainerSnapshot,
    allowedStates: [RuntimeStatus]
  ) async throws -> ContainerSnapshot {
    guard let current = try await existingBuilder() else {
      throw ContainerBuildWorkerError.make(
        code: "builder-changed",
        message: "Apple’s shared BuildKit container disappeared before the reviewed action."
      )
    }
    let expectedSafety = safetySnapshot(expected)
    let currentSafety = safetySnapshot(current)
    guard
      current.configuration.creationDate == expected.configuration.creationDate,
      currentSafety.identity == expectedSafety.identity,
      currentSafety.configuration == expectedSafety.configuration,
      allowedStates.contains(current.status)
    else {
      throw ContainerBuildWorkerError.make(
        code: "builder-changed",
        message:
          "Apple’s shared BuildKit container changed after review. NativeContainers did not perform the destructive action."
      )
    }
    return current
  }

  private func cleanUpFailedBuilder(_ created: ContainerSnapshot) async {
    guard let current = try? await existingBuilder() else { return }
    let expectedSafety = safetySnapshot(created)
    let currentSafety = safetySnapshot(current)
    guard
      current.configuration.creationDate == created.configuration.creationDate,
      currentSafety.identity == expectedSafety.identity,
      currentSafety.configuration == expectedSafety.configuration
    else { return }

    let state = runtimeState(current.status)
    switch ContainerBuilderSafetyPolicy.failedCreateCleanupAction(for: state) {
    case .deleteStopped:
      do {
        _ = try await requireUnchangedBuilder(created, allowedStates: [.stopped])
        try await client.delete(id: Builder.builderContainerId)
      } catch {
        logger.warning("failed to clean up the reviewed builder", metadata: ["error": "\(error)"])
      }
    case .leaveIntact:
      logger.warning(
        "left failed builder intact because it may have started or changed outside the reviewed operation",
        metadata: ["state": "\(state.rawValue)"]
      )
    }
  }

  private func safetyDecision(
    existing: ContainerSnapshot?,
    resolved: ResolvedConfiguration,
    imageDescriptorDigest: String,
    requested: ContainerBuilderConfiguration
  ) -> ContainerBuilderSafetyDecision {
    ContainerBuilderSafetyPolicy.evaluate(
      snapshot: safetySnapshot(existing),
      identity: identityRequirements(resolved),
      desiredConfiguration: desiredConfiguration(
        resolved,
        imageDescriptorDigest: imageDescriptorDigest
      ),
      authorization: ContainerBuilderSafetyAuthorization(
        allowsRecreateStoppedBuilder: requested.allowsRecreateStoppedBuilder,
        allowsStopRunningBuilder: requested.allowsStopRunningBuilder
      )
    )
  }

  private func safetySnapshot(_ snapshot: ContainerSnapshot?) -> ContainerBuilderSafetySnapshot {
    ContainerBuilderSnapshotAdapter.safetySnapshot(snapshot)
  }

  private func reviewedSnapshot(
    _ snapshot: ContainerSnapshot
  ) -> ContainerBuilderReviewedSnapshot {
    ContainerBuilderSnapshotAdapter.reviewedSnapshot(snapshot)
  }

  private func identityRequirements(
    _ resolved: ResolvedConfiguration
  ) -> ContainerBuilderIdentityRequirements {
    ContainerBuilderSnapshotAdapter.identityRequirements(
      exportsRootPath: resolved.exportsRoot.path(percentEncoded: false),
      builtinNetworkID: resolved.builtinNetworkID
    )
  }

  private func desiredConfiguration(
    _ resolved: ResolvedConfiguration,
    imageDescriptorDigest: String
  ) -> ContainerBuilderDesiredConfiguration {
    ContainerBuilderDesiredConfiguration(
      image: resolved.system.build.image,
      imageDescriptorDigest: imageDescriptorDigest,
      cpuCount: resolved.resources.cpus,
      memoryBytes: resolved.resources.memoryInBytes,
      rosettaEnabled: resolved.useRosetta,
      managedColorEnvironment: resolved.managedEnvironment,
      dns: resolved.builderDNS
    )
  }

  private func runtimeState(_ status: RuntimeStatus) -> ContainerBuilderRuntimeState {
    ContainerBuilderSnapshotAdapter.runtimeState(status)
  }

  private func safetyError(
    _ decision: ContainerBuilderSafetyDecision
  ) -> ContainerBuildWorkerError {
    let code = decision.errorCode?.rawValue ?? "builder-policy"
    let details =
      (decision.identityMismatches.map(\.rawValue)
      + decision.configurationMismatches.map(\.rawValue)).joined(separator: ", ")
    let message: String =
      switch decision.errorCode {
      case .conflict:
        "A container named “\(Builder.builderContainerId)” exists but is not Apple’s pinned builder. NativeContainers will not modify it."
      case .stopping:
        "Apple’s shared BuildKit container is stopping. Wait for it to finish before retrying."
      case .unknownState:
        "Apple’s shared BuildKit container is in an unknown state. NativeContainers will not modify it."
      case .runningDrift:
        "Apple’s shared BuildKit container is running with different settings. Stopping it could interrupt another build and requires explicit confirmation."
      case .stoppedDrift:
        "Apple’s stopped BuildKit container has different settings. Recreating it and its cache requires explicit confirmation."
      case nil:
        "Apple’s shared BuildKit container failed its safety policy."
      }
    return ContainerBuildWorkerError.make(
      code: code,
      message: details.isEmpty ? message : "\(message) Details: \(details)."
    )
  }

  private func progressHandler(
    phase: ContainerBuildWorkerPhase
  ) -> ProgressUpdateHandler {
    { events in
      for event in events {
        guard case .setDescription(let message) = event else { continue }
        try? await writer.send(.progress(phase, message: message))
      }
    }
  }

  private func emit(_ message: String) async throws {
    try await writer.send(.progress(.preparingBuilder, message: message))
  }

  private func validate(_ configuration: ContainerBuilderConfiguration) throws {
    if let cpuCount = configuration.cpuCount, !(1...32).contains(cpuCount) {
      throw ContainerBuildWorkerError.make(
        code: "builder-cpu",
        message: "Builder CPU count must be between 1 and 32."
      )
    }
    if let memoryMiB = configuration.memoryMiB, !(512...131_072).contains(memoryMiB) {
      throw ContainerBuildWorkerError.make(
        code: "builder-memory",
        message: "Builder memory must be between 512 MiB and 128 GiB."
      )
    }
  }

  private func resolve(
    _ requested: ContainerBuilderConfiguration
  ) async throws -> ResolvedConfiguration {
    try validate(requested)
    let health = try await ClientHealthCheck.ping(timeout: .seconds(10))
    let applicationRoot = FilePath(health.appRoot.path(percentEncoded: false))
    let installRoot = FilePath(health.installRoot.path(percentEncoded: false))
    let system = try await ConfigurationLoader.load(
      configurationFiles: [
        ConfigurationLoader.configurationFile(in: applicationRoot, of: .appRoot),
        ConfigurationLoader.configurationFile(in: installRoot, of: .installRoot),
      ]
    )
    let resources = try Parser.resources(
      cpus: requested.cpuCount.map(Int64.init),
      memory: requested.memoryMiB.map { "\($0)MiB" },
      defaultCPUs: system.build.cpus,
      defaultMemory: system.build.memory
    )
    var managedEnvironment: [String] = []
    if let colors = ProcessInfo.processInfo.environment["BUILDKIT_COLORS"] {
      managedEnvironment.append("BUILDKIT_COLORS=\(colors)")
    }
    if ProcessInfo.processInfo.environment["NO_COLOR"] != nil {
      managedEnvironment.append("NO_COLOR=true")
    }
    managedEnvironment.sort()
    guard let network = try await NetworkClient().builtin else {
      throw ContainerBuildWorkerError.make(
        code: "builder-network",
        message: "Apple’s built-in container network is unavailable."
      )
    }
    return ResolvedConfiguration(
      system: system,
      resources: resources,
      managedEnvironment: managedEnvironment,
      useRosetta: system.build.rosetta,
      exportsRoot: health.appRoot.appendingPathComponent(Self.resourceDirectoryName),
      builtinNetworkID: network.id
    )
  }
}
