import Foundation

enum AppNotificationAuthorizationStatus: Equatable, Sendable {
  case unknown
  case notDetermined
  case denied
  case authorized
  case provisional
  case unavailable

  var canRequestAuthorization: Bool {
    self == .notDetermined
  }

  var permitsDelivery: Bool {
    switch self {
    case .authorized, .provisional:
      true
    case .unknown, .notDetermined, .denied, .unavailable:
      false
    }
  }
}

enum AppNotificationChannelStatus: Equatable, Sendable {
  case unknown
  case notSupported
  case disabled
  case enabled
}

struct AppNotificationSettingsSnapshot: Equatable, Sendable {
  let authorization: AppNotificationAuthorizationStatus
  let alerts: AppNotificationChannelStatus
  let sounds: AppNotificationChannelStatus

  static let unknown = AppNotificationSettingsSnapshot(
    authorization: .unknown,
    alerts: .unknown,
    sounds: .unknown
  )

  static let unavailable = AppNotificationSettingsSnapshot(
    authorization: .unavailable,
    alerts: .notSupported,
    sounds: .notSupported
  )
}

enum AppNotificationDestination: Equatable, Sendable {
  case builds
  case macOSVirtualMachine(UUID)

  private enum PayloadKey {
    static let route = "route"
    static let identifier = "identifier"
  }

  private enum RouteValue {
    static let builds = "builds"
    static let macOSVirtualMachine = "macOSVirtualMachine"
  }

  init?(payload: [String: String]) {
    switch payload[PayloadKey.route] {
    case RouteValue.builds:
      self = .builds
    case RouteValue.macOSVirtualMachine:
      guard
        let value = payload[PayloadKey.identifier],
        let identifier = UUID(uuidString: value)
      else {
        return nil
      }
      self = .macOSVirtualMachine(identifier)
    default:
      return nil
    }
  }

  var payload: [String: String] {
    switch self {
    case .builds:
      [PayloadKey.route: RouteValue.builds]
    case .macOSVirtualMachine(let identifier):
      [
        PayloadKey.route: RouteValue.macOSVirtualMachine,
        PayloadKey.identifier: identifier.uuidString,
      ]
    }
  }

  var workspaceRoute: WorkspaceRoute {
    switch self {
    case .builds:
      .builds
    case .macOSVirtualMachine(let identifier):
      .macOSVirtualMachine(identifier)
    }
  }
}

enum AppNotificationEvent: Equatable, Sendable {
  case imageBuildSucceeded
  case imageBuildFailed
  case restoreImagePrepared(machineID: UUID, machineName: String)
  case restoreImagePreparationFailed(machineID: UUID, machineName: String)
  case virtualMachineInstallationSucceeded(machineID: UUID, machineName: String)
  case virtualMachineInstallationFailed(machineID: UUID, machineName: String)

  var title: LocalizedStringResource {
    switch self {
    case .imageBuildSucceeded:
      "Image build complete"
    case .imageBuildFailed:
      "Image build failed"
    case .restoreImagePrepared:
      "Restore image ready"
    case .restoreImagePreparationFailed:
      "Restore image preparation failed"
    case .virtualMachineInstallationSucceeded:
      "macOS installation complete"
    case .virtualMachineInstallationFailed:
      "macOS installation failed"
    }
  }

  var body: LocalizedStringResource {
    switch self {
    case .imageBuildSucceeded:
      "The image build finished successfully."
    case .imageBuildFailed:
      "The image build needs attention. Open Builds for details."
    case .restoreImagePrepared(_, let machineName):
      "Restore image preparation for \(machineName) finished successfully."
    case .restoreImagePreparationFailed(_, let machineName):
      "Restore image preparation for \(machineName) needs attention."
    case .virtualMachineInstallationSucceeded(_, let machineName):
      "macOS installation for \(machineName) finished successfully."
    case .virtualMachineInstallationFailed(_, let machineName):
      "macOS installation for \(machineName) needs attention."
    }
  }

  var destination: AppNotificationDestination {
    switch self {
    case .imageBuildSucceeded, .imageBuildFailed:
      .builds
    case .restoreImagePrepared(let machineID, _),
      .restoreImagePreparationFailed(let machineID, _),
      .virtualMachineInstallationSucceeded(let machineID, _),
      .virtualMachineInstallationFailed(let machineID, _):
      .macOSVirtualMachine(machineID)
    }
  }

  var threadIdentifier: String {
    switch destination {
    case .builds:
      "com.nativecontainers.app.builds"
    case .macOSVirtualMachine(let identifier):
      "com.nativecontainers.app.macos-vm.\(identifier.uuidString.lowercased())"
    }
  }
}
