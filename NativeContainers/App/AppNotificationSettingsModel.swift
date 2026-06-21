import Observation

@MainActor
@Observable
final class AppNotificationSettingsModel {
  private(set) var settings: AppNotificationSettingsSnapshot
  private(set) var isRefreshing = false
  private(set) var isRequestingAuthorization = false
  private(set) var errorMessage: String?

  private let service: any AppNotificationManaging

  init(
    service: any AppNotificationManaging,
    initialSettings: AppNotificationSettingsSnapshot = .unknown
  ) {
    self.service = service
    settings = initialSettings
  }

  var isWorking: Bool {
    isRefreshing || isRequestingAuthorization
  }

  func refresh() async {
    guard !isWorking else { return }

    isRefreshing = true
    defer { isRefreshing = false }

    settings = await service.settings()
    errorMessage = nil
  }

  func requestAuthorization() async {
    guard settings.authorization.canRequestAuthorization, !isWorking else {
      return
    }

    isRequestingAuthorization = true
    defer { isRequestingAuthorization = false }

    do {
      settings = try await service.requestAuthorization()
      errorMessage = nil
    } catch {
      settings = await service.settings()
      errorMessage = error.localizedDescription
    }
  }
}
