import ContainerAPIClient
import ContainerResource
import Foundation

struct ComposeRuntimeContainerSnapshot: Equatable, Sendable {
  let record: ContainerRecord
  let imageDigest: String
  let stopSignal: String?
  let hasPublishedSockets: Bool
  let usesSSHAgent: Bool
}

protocol ComposeContainerMutationTransport: Sendable {
  func list() async throws -> [ComposeRuntimeContainerSnapshot]
  func start(id: String) async throws
  func signal(id: String, signal: String) async throws
  func delete(id: String) async throws
}

struct AppleComposeContainerMutationClient: ComposeContainerMutationTransport {
  private let client: ContainerClient

  init(client: ContainerClient = ContainerClient()) {
    self.client = client
  }

  func list() async throws -> [ComposeRuntimeContainerSnapshot] {
    try await client.list().map { snapshot in
      ComposeRuntimeContainerSnapshot(
        record: AppleRuntimeInventoryService.containerRecord(from: snapshot),
        imageDigest: snapshot.configuration.image.digest,
        stopSignal: snapshot.configuration.stopSignal,
        hasPublishedSockets: !snapshot.configuration.publishedSockets.isEmpty,
        usesSSHAgent: snapshot.configuration.ssh
      )
    }
  }

  func start(id: String) async throws {
    let process = try await client.bootstrap(
      id: id,
      stdio: [nil, nil, nil],
      dynamicEnv: [:]
    )
    try await process.start()
  }

  func signal(id: String, signal: String) async throws {
    try await client.kill(id: id, signal: signal)
  }

  func delete(id: String) async throws {
    try await client.delete(id: id)
  }
}

protocol ComposeMutationSleeping: Sendable {
  func sleep(for duration: Duration) async throws
}

struct TaskComposeMutationSleeper: ComposeMutationSleeping {
  func sleep(for duration: Duration) async throws {
    try await Task.sleep(for: duration)
  }
}

struct ComposeMutationTiming: Equatable, Sendable {
  let gracefulPollAttempts: Int
  let confirmationPollAttempts: Int
  let pollInterval: Duration

  init(
    gracefulPollAttempts: Int = 20,
    confirmationPollAttempts: Int = 20,
    pollInterval: Duration = .milliseconds(250)
  ) {
    precondition(gracefulPollAttempts > 0)
    precondition(confirmationPollAttempts > 0)
    self.gracefulPollAttempts = gracefulPollAttempts
    self.confirmationPollAttempts = confirmationPollAttempts
    self.pollInterval = pollInterval
  }
}

protocol ComposeContainerActionExecuting: Sendable {
  func execute(
    _ action: ComposeProjectContainerAction,
    killStuckContainers: Bool
  ) async throws
}

struct ComposeContainerActionService: ComposeContainerActionExecuting {
  private let containers: any ComposeContainerMutationTransport
  private let sleeper: any ComposeMutationSleeping
  private let timing: ComposeMutationTiming

  init(
    containers: any ComposeContainerMutationTransport =
      AppleComposeContainerMutationClient(),
    sleeper: any ComposeMutationSleeping = TaskComposeMutationSleeper(),
    timing: ComposeMutationTiming = ComposeMutationTiming()
  ) {
    self.containers = containers
    self.sleeper = sleeper
    self.timing = timing
  }

  func execute(
    _ action: ComposeProjectContainerAction,
    killStuckContainers: Bool
  ) async throws {
    let identity = try requiredIdentity(for: action)
    switch action.operation {
    case .create:
      throw ComposeProjectLifecycleError.observedStateChanged
    case .converge, .start:
      try await start(identity)
    case .stop:
      try await stop(identity, killStuckContainers: killStuckContainers)
    case .removeDeclared, .removeOrphan:
      try await stop(identity, killStuckContainers: killStuckContainers)
      try await delete(identity)
    }
  }

  private func start(_ identity: ComposeProjectContainerIdentity) async throws {
    let snapshot = try await requireContainer(identity)
    if snapshot.record.state == .running { return }
    guard
      snapshot.record.ports.isEmpty,
      !snapshot.hasPublishedSockets,
      !snapshot.usesSSHAgent
    else {
      throw ComposeProjectLifecycleError.observedStateChanged
    }

    do {
      try await containers.start(id: identity.id)
    } catch {
      if let reconciled = try await currentContainer(identity),
        reconciled.record.state == .running
      {
        return
      }
      throw error
    }
    guard try await waitForContainer(identity, running: true) != nil else {
      throw ComposeProjectLifecycleError.postconditionNotMet(
        "Container \(identity.id) did not confirm Running after start."
      )
    }
  }

  private func stop(
    _ identity: ComposeProjectContainerIdentity,
    killStuckContainers: Bool
  ) async throws {
    let snapshot = try await requireContainer(identity)
    guard snapshot.record.state == .running || snapshot.record.state == .stopping else {
      return
    }

    do {
      try await containers.signal(
        id: identity.id,
        signal: snapshot.stopSignal ?? "TERM"
      )
    } catch {
      if let reconciled = try await currentContainer(identity),
        reconciled.record.state != .running,
        reconciled.record.state != .stopping
      {
        return
      }
      throw error
    }

    if try await waitForContainer(identity, running: false) != nil {
      return
    }
    guard killStuckContainers else {
      throw ComposeProjectLifecycleError.partialCompletion(
        "Container \(identity.id) remained running after its graceful stop timeout; automatic KILL was disabled."
      )
    }

    let beforeKill = try await requireContainer(identity)
    guard beforeKill.record.state == .running || beforeKill.record.state == .stopping else {
      return
    }
    do {
      try await containers.signal(id: identity.id, signal: "KILL")
    } catch {
      if let reconciled = try await currentContainer(identity),
        reconciled.record.state != .running,
        reconciled.record.state != .stopping
      {
        return
      }
      throw error
    }
    guard
      try await waitForContainer(
        identity,
        running: false,
        attempts: timing.confirmationPollAttempts
      ) != nil
    else {
      throw ComposeProjectLifecycleError.postconditionNotMet(
        "Container \(identity.id) did not confirm exit after KILL."
      )
    }
  }

  private func delete(_ identity: ComposeProjectContainerIdentity) async throws {
    let snapshot = try await requireContainer(identity)
    guard snapshot.record.state != .running, snapshot.record.state != .stopping else {
      throw ComposeProjectLifecycleError.observedStateChanged
    }
    do {
      try await containers.delete(id: identity.id)
    } catch {
      if try await currentContainer(identity) == nil {
        return
      }
      throw error
    }
    guard
      try await waitForContainerAbsence(
        identity,
        attempts: timing.confirmationPollAttempts
      )
    else {
      throw ComposeProjectLifecycleError.postconditionNotMet(
        "Container \(identity.id) remained present after deletion."
      )
    }
  }

  private func requiredIdentity(
    for action: ComposeProjectContainerAction
  ) throws -> ComposeProjectContainerIdentity {
    guard let identity = action.expectedIdentity else {
      throw ComposeProjectLifecycleError.observedStateChanged
    }
    return identity
  }

  private func requireContainer(
    _ identity: ComposeProjectContainerIdentity
  ) async throws -> ComposeRuntimeContainerSnapshot {
    guard let snapshot = try await currentContainer(identity) else {
      throw ComposeProjectLifecycleError.observedStateChanged
    }
    return snapshot
  }

  private func currentContainer(
    _ identity: ComposeProjectContainerIdentity
  ) async throws -> ComposeRuntimeContainerSnapshot? {
    let matches = try await containers.list().filter { $0.record.id == identity.id }
    guard matches.count <= 1 else {
      throw ComposeProjectLifecycleError.observedStateChanged
    }
    guard let snapshot = matches.first else { return nil }
    guard
      identity.matches(snapshot.record),
      identity.imageDigest == nil || identity.imageDigest == snapshot.imageDigest
    else {
      throw ComposeProjectLifecycleError.observedStateChanged
    }
    return snapshot
  }

  private func waitForContainer(
    _ identity: ComposeProjectContainerIdentity,
    running: Bool,
    attempts: Int? = nil
  ) async throws -> ComposeRuntimeContainerSnapshot? {
    let maximumAttempts = attempts ?? timing.gracefulPollAttempts
    for attempt in 0..<maximumAttempts {
      guard let snapshot = try await currentContainer(identity) else {
        return nil
      }
      let isRunning =
        snapshot.record.state == .running || snapshot.record.state == .stopping
      if isRunning == running {
        return snapshot
      }
      if attempt + 1 < maximumAttempts {
        try await sleeper.sleep(for: timing.pollInterval)
      }
    }
    return nil
  }

  private func waitForContainerAbsence(
    _ identity: ComposeProjectContainerIdentity,
    attempts: Int
  ) async throws -> Bool {
    for attempt in 0..<attempts {
      if try await currentContainer(identity) == nil {
        return true
      }
      if attempt + 1 < attempts {
        try await sleeper.sleep(for: timing.pollInterval)
      }
    }
    return false
  }
}
