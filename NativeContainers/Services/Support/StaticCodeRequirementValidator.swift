import Foundation
import Security

enum StaticCodeRequirementValidationError: Error, Equatable, Sendable {
  case codeObjectCreationFailed(OSStatus)
  case requirementCreationFailed(OSStatus)
  case requirementFailed
  case signatureInvalid(OSStatus)
}

struct StaticCodeRequirementValidator: Sendable {
  func validate(codeAt url: URL, requirement requirementText: String) throws {
    var staticCode: SecStaticCode?
    let codeStatus = SecStaticCodeCreateWithPath(
      url.standardizedFileURL as CFURL,
      SecCSFlags(rawValue: 0),
      &staticCode
    )
    guard codeStatus == errSecSuccess, let staticCode else {
      throw StaticCodeRequirementValidationError.codeObjectCreationFailed(codeStatus)
    }

    var requirement: SecRequirement?
    let requirementStatus = SecRequirementCreateWithString(
      requirementText as CFString,
      SecCSFlags(rawValue: 0),
      &requirement
    )
    guard requirementStatus == errSecSuccess, let requirement else {
      throw StaticCodeRequirementValidationError.requirementCreationFailed(
        requirementStatus
      )
    }

    let validationStatus = SecStaticCodeCheckValidity(
      staticCode,
      SecCSFlags(rawValue: 0),
      requirement
    )
    guard validationStatus == errSecSuccess else {
      if validationStatus == errSecCSReqFailed {
        throw StaticCodeRequirementValidationError.requirementFailed
      }
      throw StaticCodeRequirementValidationError.signatureInvalid(validationStatus)
    }
  }
}
