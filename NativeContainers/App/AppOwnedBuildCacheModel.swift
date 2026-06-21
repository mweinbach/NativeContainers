import Foundation
import Observation

@MainActor
@Observable
final class AppOwnedBuildCacheModel {
  private(set) var snapshot: AppOwnedBuildCacheSnapshot?
  private(set) var maintenanceWarning: String?
  private(set) var errorMessage: String?
  private(set) var isLoading = false
  private(set) var isResetting = false

  private let service: any AppOwnedBuildCacheManaging

  init(service: any AppOwnedBuildCacheManaging) {
    self.service = service
  }

  func load() async {
    guard !isBusy else { return }
    isLoading = true
    errorMessage = nil
    maintenanceWarning = nil
    defer { isLoading = false }

    do {
      snapshot = try await service.loadCache()
    } catch is CancellationError {
      return
    } catch {
      errorMessage = error.localizedDescription
    }
  }

  @discardableResult
  func reset() async -> Bool {
    guard !isBusy else { return false }
    isResetting = true
    errorMessage = nil
    maintenanceWarning = nil
    defer { isResetting = false }

    do {
      let receipt = try await service.resetCache()
      snapshot = nil
      maintenanceWarning = receipt.maintenanceWarning
      return true
    } catch is CancellationError {
      await refreshAfterAttempt()
      return false
    } catch {
      errorMessage = error.localizedDescription
      await refreshAfterAttempt()
      return false
    }
  }

  var isBusy: Bool { isLoading || isResetting }

  private func refreshAfterAttempt() async {
    do {
      snapshot = try await service.loadCache()
    } catch {
      if errorMessage == nil {
        errorMessage = error.localizedDescription
      }
    }
  }
}
