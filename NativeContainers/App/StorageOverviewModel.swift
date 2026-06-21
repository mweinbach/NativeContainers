import Foundation
import Observation

@MainActor
@Observable
final class StorageOverviewModel {
  private(set) var appleRuntimeUsage: AppleRuntimeStorageUsage?
  private(set) var virtualMachineUsage: VirtualMachineStorageSummary?
  private(set) var appleRuntimeErrorMessage: String?
  private(set) var virtualMachineErrorMessage: String?
  private(set) var isLoadingAppleRuntime = false
  private(set) var isLoadingVirtualMachines = false
  private(set) var hasAttemptedAppleRuntime = false
  private(set) var hasAttemptedVirtualMachines = false

  private let service: any StorageUsageLoading

  @ObservationIgnored
  private var operationTask: Task<Void, Never>?

  init(
    service: any StorageUsageLoading,
    appleRuntimeUsage: AppleRuntimeStorageUsage? = nil,
    virtualMachineUsage: VirtualMachineStorageSummary? = nil,
    appleRuntimeErrorMessage: String? = nil,
    virtualMachineErrorMessage: String? = nil
  ) {
    self.service = service
    self.appleRuntimeUsage = appleRuntimeUsage
    self.virtualMachineUsage = virtualMachineUsage
    self.appleRuntimeErrorMessage = appleRuntimeErrorMessage
    self.virtualMachineErrorMessage = virtualMachineErrorMessage
    hasAttemptedAppleRuntime =
      appleRuntimeUsage != nil || appleRuntimeErrorMessage != nil
    hasAttemptedVirtualMachines =
      virtualMachineUsage != nil || virtualMachineErrorMessage != nil
  }

  var isLoading: Bool {
    isLoadingAppleRuntime || isLoadingVirtualMachines
  }

  var hasAttempted: Bool {
    hasAttemptedAppleRuntime || hasAttemptedVirtualMachines
  }

  func startRefresh() {
    start { model in
      await model.refresh()
    }
  }

  func startAppleRuntimeRefresh() {
    start { model in
      await model.refreshAppleRuntime()
    }
  }

  func startVirtualMachineRefresh() {
    start { model in
      await model.refreshVirtualMachines()
    }
  }

  func cancelCurrentOperation() {
    operationTask?.cancel()
  }

  func refresh() async {
    guard !isLoading else { return }
    async let appleRuntime: Void = refreshAppleRuntime()
    async let virtualMachines: Void = refreshVirtualMachines()
    _ = await (appleRuntime, virtualMachines)
  }

  func refreshAppleRuntime() async {
    guard !isLoadingAppleRuntime else { return }
    hasAttemptedAppleRuntime = true
    isLoadingAppleRuntime = true
    defer { isLoadingAppleRuntime = false }

    let service = self.service
    let result = await Self.capture {
      try await service.loadAppleRuntimeStorageUsage()
    }
    guard !Task.isCancelled else { return }
    switch result {
    case .success(let usage):
      appleRuntimeUsage = usage
      appleRuntimeErrorMessage = nil
    case .failure(let message):
      appleRuntimeErrorMessage = message
    case .cancelled:
      break
    }
  }

  func refreshVirtualMachines() async {
    guard !isLoadingVirtualMachines else { return }
    hasAttemptedVirtualMachines = true
    isLoadingVirtualMachines = true
    defer { isLoadingVirtualMachines = false }

    let service = self.service
    let result = await Self.capture {
      try await service.loadVirtualMachineStorageUsage()
    }
    guard !Task.isCancelled else { return }
    switch result {
    case .success(let usage):
      virtualMachineUsage = usage
      virtualMachineErrorMessage = nil
    case .failure(let message):
      virtualMachineErrorMessage = message
    case .cancelled:
      break
    }
  }

  private func start(
    _ operation: @escaping @MainActor (StorageOverviewModel) async -> Void
  ) {
    guard operationTask == nil else { return }
    operationTask = Task { [weak self] in
      guard let self else { return }
      await operation(self)
      operationTask = nil
    }
  }

  nonisolated private static func capture<Value: Sendable>(
    _ operation: @escaping @Sendable () async throws -> Value
  ) async -> StorageLoadResult<Value> {
    do {
      try Task.checkCancellation()
      let value = try await operation()
      try Task.checkCancellation()
      return .success(value)
    } catch is CancellationError {
      return .cancelled
    } catch {
      if Task.isCancelled {
        return .cancelled
      }
      return .failure(error.localizedDescription)
    }
  }
}

private enum StorageLoadResult<Value: Sendable>: Sendable {
  case success(Value)
  case failure(String)
  case cancelled
}
