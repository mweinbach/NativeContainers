import Foundation
import OSLog
import UserNotifications

protocol AppNotificationManaging: Sendable {
  @MainActor
  func settings() async -> AppNotificationSettingsSnapshot

  @MainActor
  func requestAuthorization() async throws -> AppNotificationSettingsSnapshot

  @MainActor
  func deliver(_ event: AppNotificationEvent) async

  @MainActor
  func setResponseHandler(
    _ handler: @escaping @MainActor @Sendable (AppNotificationDestination) async -> Void
  )
}

@MainActor
protocol UserNotificationCenterClient: AnyObject {
  func install(delegate: any UNUserNotificationCenterDelegate)
  func settings() async -> AppNotificationSettingsSnapshot
  func requestAuthorization(options: UNAuthorizationOptions) async throws
  func add(_ request: UNNotificationRequest) async throws
}

@MainActor
final class SystemUserNotificationCenterClient: UserNotificationCenterClient {
  private let center: UNUserNotificationCenter

  init(center: UNUserNotificationCenter = .current()) {
    self.center = center
  }

  func install(delegate: any UNUserNotificationCenterDelegate) {
    center.delegate = delegate
  }

  func settings() async -> AppNotificationSettingsSnapshot {
    let settings = await center.notificationSettings()
    return AppNotificationSettingsSnapshot(
      authorization: Self.authorizationStatus(from: settings.authorizationStatus),
      alerts: Self.channelStatus(from: settings.alertSetting),
      sounds: Self.channelStatus(from: settings.soundSetting)
    )
  }

  func requestAuthorization(options: UNAuthorizationOptions) async throws {
    _ = try await center.requestAuthorization(options: options)
  }

  func add(_ request: UNNotificationRequest) async throws {
    try await center.add(request)
  }

  nonisolated static func authorizationStatus(
    from status: UNAuthorizationStatus
  ) -> AppNotificationAuthorizationStatus {
    switch status {
    case .notDetermined:
      .notDetermined
    case .denied:
      .denied
    case .authorized:
      .authorized
    case .provisional:
      .provisional
    case .ephemeral:
      .unknown
    @unknown default:
      .unknown
    }
  }

  nonisolated static func channelStatus(
    from status: UNNotificationSetting
  ) -> AppNotificationChannelStatus {
    switch status {
    case .notSupported:
      .notSupported
    case .disabled:
      .disabled
    case .enabled:
      .enabled
    @unknown default:
      .unknown
    }
  }
}

@MainActor
final class UserNotificationService: AppNotificationManaging {
  private static let logger = Logger(
    subsystem: "com.nativecontainers.app",
    category: "notifications"
  )

  private let center: any UserNotificationCenterClient
  private let responseRouter: AppNotificationResponseRouter
  private let notificationDelegate: AppUserNotificationCenterDelegate

  init(
    center: any UserNotificationCenterClient = SystemUserNotificationCenterClient()
  ) {
    let responseRouter = AppNotificationResponseRouter()
    let notificationDelegate = AppUserNotificationCenterDelegate(router: responseRouter)

    self.center = center
    self.responseRouter = responseRouter
    self.notificationDelegate = notificationDelegate

    center.install(delegate: notificationDelegate)
  }

  func settings() async -> AppNotificationSettingsSnapshot {
    await center.settings()
  }

  func requestAuthorization() async throws -> AppNotificationSettingsSnapshot {
    try await center.requestAuthorization(options: [.alert, .sound])
    return await center.settings()
  }

  func deliver(_ event: AppNotificationEvent) async {
    let currentSettings = await center.settings()
    guard currentSettings.authorization.permitsDelivery else { return }

    do {
      try await center.add(Self.request(for: event))
    } catch {
      Self.logger.error("Unable to deliver a NativeContainers notification.")
    }
  }

  func setResponseHandler(
    _ handler: @escaping @MainActor @Sendable (AppNotificationDestination) async -> Void
  ) {
    responseRouter.setHandler(handler)
  }

  static func request(for event: AppNotificationEvent) -> UNNotificationRequest {
    let content = UNMutableNotificationContent()
    content.title = String(localized: event.title)
    content.body = String(localized: event.body)
    content.sound = .default
    content.threadIdentifier = event.threadIdentifier
    content.userInfo = event.destination.payload

    return UNNotificationRequest(
      identifier: "com.nativecontainers.app.notification.\(UUID().uuidString)",
      content: content,
      trigger: nil
    )
  }
}

struct UnavailableAppNotificationService: AppNotificationManaging {
  @MainActor
  func settings() async -> AppNotificationSettingsSnapshot {
    .unavailable
  }

  @MainActor
  func requestAuthorization() async throws -> AppNotificationSettingsSnapshot {
    throw AppNotificationServiceError.unavailable
  }

  @MainActor
  func deliver(_ event: AppNotificationEvent) async {}

  @MainActor
  func setResponseHandler(
    _ handler: @escaping @MainActor @Sendable (AppNotificationDestination) async -> Void
  ) {}
}

@MainActor
private final class AppNotificationResponseRouter {
  private var handler: (@MainActor @Sendable (AppNotificationDestination) async -> Void)?

  func setHandler(
    _ handler: @escaping @MainActor @Sendable (AppNotificationDestination) async -> Void
  ) {
    self.handler = handler
  }

  func route(to destination: AppNotificationDestination) async {
    await handler?(destination)
  }
}

private final class AppUserNotificationCenterDelegate:
  NSObject,
  UNUserNotificationCenterDelegate,
  @unchecked Sendable
{
  private let router: AppNotificationResponseRouter

  init(router: AppNotificationResponseRouter) {
    self.router = router
  }

  func userNotificationCenter(
    _ center: UNUserNotificationCenter,
    willPresent notification: UNNotification
  ) async -> UNNotificationPresentationOptions {
    []
  }

  func userNotificationCenter(
    _ center: UNUserNotificationCenter,
    didReceive response: UNNotificationResponse
  ) async {
    guard response.actionIdentifier == UNNotificationDefaultActionIdentifier else {
      return
    }

    let userInfo = response.notification.request.content.userInfo
    let payload = userInfo.reduce(into: [String: String]()) { result, entry in
      guard let key = entry.key as? String, let value = entry.value as? String else {
        return
      }
      result[key] = value
    }
    guard let destination = AppNotificationDestination(payload: payload) else {
      return
    }

    await router.route(to: destination)
  }
}

private enum AppNotificationServiceError: LocalizedError {
  case unavailable

  var errorDescription: String? {
    String(localized: "Notifications are unavailable in this app environment.")
  }
}
