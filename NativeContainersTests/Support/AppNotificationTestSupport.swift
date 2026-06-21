import Foundation

@testable import NativeContainers

@MainActor
final class RecordingAppNotificationService: AppNotificationManaging {
  var currentSettings: AppNotificationSettingsSnapshot
  var authorizationResult: AppNotificationSettingsSnapshot?
  var authorizationError: (any Error)?

  private(set) var authorizationRequestCount = 0
  private(set) var events: [AppNotificationEvent] = []

  private var responseHandler: (@MainActor @Sendable (AppNotificationDestination) async -> Void)?

  init(settings: AppNotificationSettingsSnapshot = .unavailable) {
    currentSettings = settings
  }

  func settings() async -> AppNotificationSettingsSnapshot {
    currentSettings
  }

  func requestAuthorization() async throws -> AppNotificationSettingsSnapshot {
    authorizationRequestCount += 1
    if let authorizationError {
      throw authorizationError
    }
    if let authorizationResult {
      currentSettings = authorizationResult
    }
    return currentSettings
  }

  func deliver(_ event: AppNotificationEvent) async {
    events.append(event)
  }

  func setResponseHandler(
    _ handler: @escaping @MainActor @Sendable (AppNotificationDestination) async -> Void
  ) {
    responseHandler = handler
  }

  func simulateResponse(to destination: AppNotificationDestination) async {
    await responseHandler?(destination)
  }
}
