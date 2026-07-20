import AppKit
import Foundation

struct NativeContainersLinuxRuntimeGeneration: Equatable, Hashable, Sendable, Identifiable {
  let id: UUID
  let generation: UUID

  init(id: UUID, generation: UUID) {
    self.id = id
    self.generation = generation
  }
}

protocol NativeContainersLinuxRuntimeLifecycle: Sendable {
  func reconcileLaunchOwnership() async throws
  func activeGenerations() async throws -> [NativeContainersLinuxRuntimeGeneration]
  func quiesceAndStop(
    _ generation: NativeContainersLinuxRuntimeGeneration,
    deadline: ContinuousClock.Instant
  ) async throws -> Bool
  func forceStop(
    _ generation: NativeContainersLinuxRuntimeGeneration,
    deadline: ContinuousClock.Instant
  ) async -> Bool
}

@MainActor
protocol NativeContainersApplicationLifecycleCoordinating: AnyObject, Sendable {
  func install()
  func reconcileLaunch() async throws
  func startControlServer() throws
  func terminateApplication() async -> Bool
}

@MainActor
final class NativeContainersApplicationLifecycleCoordinator: NSObject,
  NSApplicationDelegate,
  NativeContainersApplicationLifecycleCoordinating,
  @unchecked Sendable
{
  private let server: any NativeContainersControlServing
  private let runtime: any NativeContainersLinuxRuntimeLifecycle
  private let clock = ContinuousClock()
  private var isTerminating = false
  private var terminationTask: Task<Void, Never>?
  private var reply: ((Bool) -> Void)?

  init(
    server: any NativeContainersControlServing,
    runtime: any NativeContainersLinuxRuntimeLifecycle,
    terminationReply: ((Bool) -> Void)? = nil
  ) {
    self.server = server
    self.runtime = runtime
    reply = terminationReply
    super.init()
  }

  deinit { terminationTask?.cancel() }
  func install() {
    NSApplication.shared.delegate = self
    Task { @MainActor [weak self] in
      guard let self else { return }
      do {
        try await reconcileLaunch()
        try startControlServer()
      } catch {
        server.stop()
      }
    }
  }

  func reconcileLaunch() async throws {
    try await runtime.reconcileLaunchOwnership()
  }

  func startControlServer() throws {
    try server.start()
  }

  func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
    guard !isTerminating else { return .terminateLater }
    isTerminating = true
    terminationTask = Task { @MainActor [weak self] in
      guard let self else { return }
      let stopped = await terminateApplication()
      if let reply {
        reply(stopped)
      } else {
        NSApp.reply(toApplicationShouldTerminate: stopped)
      }
    }
    return .terminateLater
  }

  func terminateApplication() async -> Bool {
    guard isTerminating || terminationTask == nil else { return false }
    isTerminating = true
    server.stopAcceptingMutations()
    let deadline = clock.now.advanced(by: .seconds(30))
    let gracefulDeadline = clock.now.advanced(by: .seconds(20))
    var generations: [NativeContainersLinuxRuntimeGeneration] = []
    do { generations = try await runtime.activeGenerations() } catch {
      server.stop()
      return false
    }

    let runtime = self.runtime
    let results = await withTaskGroup(
      of: (NativeContainersLinuxRuntimeGeneration, Bool).self,
      returning: [(NativeContainersLinuxRuntimeGeneration, Bool)].self
    ) { group in
      for generation in generations {
        group.addTask {
          do {
            return (
              generation,
              try await runtime.quiesceAndStop(
                generation,
                deadline: gracefulDeadline
              )
            )
          } catch {
            return (generation, false)
          }
        }
      }
      var values: [(NativeContainersLinuxRuntimeGeneration, Bool)] = []
      for await value in group { values.append(value) }
      return values
    }
    let failed = results.compactMap { generation, stopped in
      stopped ? nil : generation
    }
    var allStopped = failed.isEmpty
    if !allStopped {
      let fallback = await withTaskGroup(of: Bool.self, returning: [Bool].self) { group in
        for generation in failed {
          group.addTask {
            await runtime.forceStop(generation, deadline: deadline)
          }
        }
        var values: [Bool] = []
        for await value in group { values.append(value) }
        return values
      }
      allStopped = fallback.allSatisfy { $0 }
    }
    server.stop()
    return allStopped
  }
}
