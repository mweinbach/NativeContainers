import Foundation
import Observation

@MainActor
@Observable
final class NativeRuntimeDistributionModel {
  private(set) var status: NativeRuntimeDistributionStatus?
  private(set) var isWorking = false
  private(set) var errorMessage: String?

  private let service: any NativeRuntimeDistributionManaging
  private let didMutate: @MainActor @Sendable () async -> Void

  init(
    service: any NativeRuntimeDistributionManaging,
    didMutate: @escaping @MainActor @Sendable () async -> Void = {}
  ) {
    self.service = service
    self.didMutate = didMutate
  }

  func refresh() async {
    guard !isWorking else { return }
    isWorking = true
    errorMessage = nil
    status = await service.status()
    isWorking = false
  }

  func activateAppleRuntime() async {
    await perform(.activateApple)
  }

  func activateNativeRuntime() async {
    await perform(.activateNative)
  }

  func cloneAppleDataAndActivateNativeRuntime() async {
    await perform(.cloneAndActivateNative)
  }

  func clearError() {
    errorMessage = nil
  }

  private enum Operation {
    case activateApple
    case activateNative
    case cloneAndActivateNative
  }

  private func perform(_ operation: Operation) async {
    guard !isWorking else { return }
    isWorking = true
    errorMessage = nil
    defer { isWorking = false }

    do {
      status =
        switch operation {
        case .activateApple:
          try await service.activateAppleRuntime()
        case .activateNative:
          try await service.activateNativeRuntime()
        case .cloneAndActivateNative:
          try await service.cloneAppleDataAndActivateNativeRuntime()
        }
      await didMutate()
    } catch is CancellationError {
      status = await service.status()
      await didMutate()
    } catch {
      errorMessage = error.localizedDescription
      status = await service.status()
      await didMutate()
    }
  }
}
