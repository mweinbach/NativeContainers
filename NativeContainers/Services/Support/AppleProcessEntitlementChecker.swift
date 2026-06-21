import Foundation
import Security

protocol ProcessEntitlementChecking: Sendable {
  func hasBooleanEntitlement(_ key: String) -> Bool
}

struct AppleProcessEntitlementChecker: ProcessEntitlementChecking {
  func hasBooleanEntitlement(_ key: String) -> Bool {
    guard let task = SecTaskCreateFromSelf(nil),
      let value = SecTaskCopyValueForEntitlement(
        task,
        key as CFString,
        nil
      )
    else {
      return false
    }
    return value as? Bool == true
  }
}
