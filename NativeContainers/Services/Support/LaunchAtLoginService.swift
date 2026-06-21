import Foundation
import ServiceManagement

protocol LaunchAtLoginManaging: Sendable {
  @MainActor
  func status() -> LaunchAtLoginStatus

  @MainActor
  @discardableResult
  func setEnabled(_ enabled: Bool) throws -> LaunchAtLoginStatus
}

struct SMAppServiceLaunchAtLoginService: LaunchAtLoginManaging {
  private let registration: any MainApplicationLoginItemRegistering

  @MainActor
  init(
    registration: any MainApplicationLoginItemRegistering =
      SMMainApplicationLoginItemRegistration()
  ) {
    self.registration = registration
  }

  @MainActor
  func status() -> LaunchAtLoginStatus {
    registration.status
  }

  @MainActor
  @discardableResult
  func setEnabled(_ enabled: Bool) throws -> LaunchAtLoginStatus {
    if enabled {
      switch registration.status {
      case .notRegistered:
        try registration.register()
      case .enabled, .requiresApproval:
        break
      case .unavailable:
        throw LaunchAtLoginServiceError.mainApplicationUnavailable
      }
    } else {
      switch registration.status {
      case .enabled, .requiresApproval:
        try registration.unregister()
      case .notRegistered:
        break
      case .unavailable:
        throw LaunchAtLoginServiceError.mainApplicationUnavailable
      }
    }

    let result = registration.status
    guard result.isRequested == enabled else {
      throw LaunchAtLoginServiceError.requestedStateNotReached
    }
    return result
  }

  static func status(from status: SMAppService.Status) -> LaunchAtLoginStatus {
    switch status {
    case .notRegistered:
      .notRegistered
    case .enabled:
      .enabled
    case .requiresApproval:
      .requiresApproval
    case .notFound:
      .unavailable
    @unknown default:
      .unavailable
    }
  }
}

@MainActor
protocol MainApplicationLoginItemRegistering: Sendable {
  var status: LaunchAtLoginStatus { get }
  func register() throws
  func unregister() throws
}

struct SMMainApplicationLoginItemRegistration: MainApplicationLoginItemRegistering {
  @MainActor
  var status: LaunchAtLoginStatus {
    SMAppServiceLaunchAtLoginService.status(from: SMAppService.mainApp.status)
  }

  @MainActor
  func register() throws {
    try SMAppService.mainApp.register()
  }

  @MainActor
  func unregister() throws {
    try SMAppService.mainApp.unregister()
  }
}

struct UnavailableLaunchAtLoginService: LaunchAtLoginManaging {
  @MainActor
  func status() -> LaunchAtLoginStatus {
    .unavailable
  }

  @MainActor
  func setEnabled(_ enabled: Bool) throws -> LaunchAtLoginStatus {
    throw LaunchAtLoginServiceError.mainApplicationUnavailable
  }
}

private enum LaunchAtLoginServiceError: LocalizedError {
  case mainApplicationUnavailable
  case requestedStateNotReached

  var errorDescription: String? {
    switch self {
    case .mainApplicationUnavailable:
      String(
        localized:
          "Launch at login is available after NativeContainers is installed as an application."
      )
    case .requestedStateNotReached:
      String(localized: "The system did not reach the requested launch-at-login state.")
    }
  }
}
