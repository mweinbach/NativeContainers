import Foundation

protocol HostResourceStateProviding: Sendable {
  func currentState() -> HostResourceState
}

protocol WorkloadCreationDefaultsProviding: Sendable {
  func currentDefaults() -> WorkloadCreationDefaults
}
