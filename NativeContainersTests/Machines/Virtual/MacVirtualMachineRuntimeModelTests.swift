import Foundation
import Testing

@testable import NativeContainers

@MainActor
struct MacVirtualMachineRuntimeModelTests {
  @Test
  func modelObservesSnapshotsAndRoutesGenerationPinnedActions() async {
    let machineID = UUID()
    let service = RuntimeModelService(machineID: machineID)
    let model = MacVirtualMachineRuntimeModel(machineID: machineID, service: service)
    let observation = Task { await model.observe() }
    await Task.yield()

    await model.start()
    await Task.yield()
    #expect(model.snapshot.state == .running)

    await model.pause()
    await Task.yield()
    #expect(model.snapshot.state == .paused)

    await model.resume()
    await model.requestStop()
    await Task.yield()
    #expect(model.snapshot.state == .stopping)

    await model.forceStop()
    await Task.yield()
    #expect(model.snapshot.state == .stopped)
    #expect(
      service.calls == [
        .start,
        .pause,
        .resume,
        .requestStop,
        .forceStop,
      ]
    )

    observation.cancel()
  }

  @Test
  func modelKeepsAnActionFailureVisible() async {
    let machineID = UUID()
    let service = RuntimeModelService(machineID: machineID)
    service.startError = .expected
    let model = MacVirtualMachineRuntimeModel(machineID: machineID, service: service)

    await model.start()

    #expect(model.errorMessage == RuntimeModelTestError.expected.localizedDescription)
    #expect(model.snapshot.state == .stopped)
  }

  @Test
  func modelRoutesSavedStateActionsThroughTheRuntimeService() async {
    let machineID = UUID()
    let service = RuntimeModelService(machineID: machineID)
    let model = MacVirtualMachineRuntimeModel(machineID: machineID, service: service)

    await model.startFresh()
    await model.suspend()
    await model.discardSavedState()

    #expect(service.calls == [.startFresh, .suspend, .discardSavedState])
  }

  @Test
  func repeatedObservationStartsOneStreamAndOneSavedStateRefresh() async {
    let machineID = UUID()
    let service = RuntimeModelService(machineID: machineID)
    let model = MacVirtualMachineRuntimeModel(machineID: machineID, service: service)

    await model.observe()
    await model.observe()

    #expect(service.updateSubscriptionCount == 1)
    #expect(service.refreshCount == 1)
  }
}

private enum RuntimeModelCall: Equatable {
  case start
  case startFresh
  case pause
  case resume
  case suspend
  case requestStop
  case forceStop
  case discardSavedState
}

@MainActor
private final class RuntimeModelService: MacVirtualMachineRuntimeManaging {
  let machineID: UUID
  let target: MacVirtualMachineRuntimeTarget
  var startError: RuntimeModelTestError?
  private(set) var calls: [RuntimeModelCall] = []
  private(set) var updateSubscriptionCount = 0
  private(set) var refreshCount = 0

  private var currentSnapshot: MacVirtualMachineRuntimeSnapshot
  private var revision: UInt64 = 0
  private var continuation: AsyncStream<MacVirtualMachineRuntimeSnapshot>.Continuation?

  init(machineID: UUID) {
    self.machineID = machineID
    target = MacVirtualMachineRuntimeTarget(machineID: machineID, generation: UUID())
    currentSnapshot = MacVirtualMachineRuntimeSnapshot(machineID: machineID)
  }

  func snapshot(for machineID: UUID) -> MacVirtualMachineRuntimeSnapshot {
    currentSnapshot
  }

  func updates(for machineID: UUID) -> AsyncStream<MacVirtualMachineRuntimeSnapshot> {
    updateSubscriptionCount += 1
    let pair = AsyncStream.makeStream(
      of: MacVirtualMachineRuntimeSnapshot.self,
      bufferingPolicy: .bufferingNewest(1)
    )
    continuation = pair.continuation
    pair.continuation.yield(currentSnapshot)
    return pair.stream
  }

  func console(for target: MacVirtualMachineRuntimeTarget) -> MacVirtualMachineConsole? { nil }

  func refreshSavedState(id: UUID) async {
    refreshCount += 1
  }

  func start(id: UUID) async throws {
    calls.append(.start)
    if let startError { throw startError }
    publish(state: .running, target: target)
  }

  func startFresh(id: UUID) async throws {
    calls.append(.startFresh)
    publish(state: .running, target: target)
  }

  func pause(target: MacVirtualMachineRuntimeTarget) async throws {
    calls.append(.pause)
    publish(state: .paused, target: target)
  }

  func resume(target: MacVirtualMachineRuntimeTarget) async throws {
    calls.append(.resume)
    publish(state: .running, target: target)
  }

  func suspend(target: MacVirtualMachineRuntimeTarget) async throws {
    calls.append(.suspend)
    publish(state: .stopped)
  }

  func requestStop(target: MacVirtualMachineRuntimeTarget) throws {
    calls.append(.requestStop)
    publish(state: .stopping, target: target)
  }

  func forceStop(target: MacVirtualMachineRuntimeTarget) async throws {
    calls.append(.forceStop)
    publish(state: .stopped)
  }

  func discardSavedState(id: UUID) async throws {
    calls.append(.discardSavedState)
  }

  private func publish(
    state: MacVirtualMachineRuntimeState,
    target: MacVirtualMachineRuntimeTarget? = nil
  ) {
    revision += 1
    currentSnapshot = MacVirtualMachineRuntimeSnapshot(
      machineID: machineID,
      revision: revision,
      target: target,
      state: state
    )
    continuation?.yield(currentSnapshot)
  }
}

private enum RuntimeModelTestError: LocalizedError {
  case expected

  var errorDescription: String? { "Expected runtime model failure." }
}
