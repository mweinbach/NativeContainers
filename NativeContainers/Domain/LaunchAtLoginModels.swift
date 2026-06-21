import Foundation

enum LaunchAtLoginStatus: Equatable, Sendable {
  case notRegistered
  case enabled
  case requiresApproval
  case unavailable

  var isRequested: Bool {
    self == .enabled || self == .requiresApproval
  }

  var canChange: Bool {
    self != .unavailable
  }
}
