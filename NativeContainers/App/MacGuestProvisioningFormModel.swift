import Foundation
import Observation

@MainActor
@Observable
final class MacGuestProvisioningFormModel {
  var fullName = ""
  var username = ""
  var password = ""
  var passwordConfirmation = ""
  var logsInAutomatically = true
  var enablesRemoteLogin = false
  private(set) var isSubmitting = false
  private(set) var errorMessage: String?

  var canSubmit: Bool {
    !isSubmitting
      && !fullName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      && !username.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      && !password.isEmpty
      && password == passwordConfirmation
  }

  func makeRequest() throws -> MacGuestProvisioningRequest {
    guard password == passwordConfirmation else {
      throw MacGuestProvisioningError.passwordsDoNotMatch
    }
    return try MacGuestProvisioningRequest(
      fullName: fullName,
      username: username,
      password: password,
      logsInAutomatically: logsInAutomatically,
      enablesRemoteLogin: enablesRemoteLogin
    )
  }

  func submit(using runtimeModel: MacVirtualMachineRuntimeModel) async -> Bool {
    guard !isSubmitting else { return false }
    errorMessage = nil

    let request: MacGuestProvisioningRequest
    do {
      request = try makeRequest()
    } catch {
      errorMessage = error.localizedDescription
      return false
    }

    isSubmitting = true
    defer { isSubmitting = false }
    let didStart = await runtimeModel.start(provisioning: request)
    guard didStart else {
      errorMessage =
        runtimeModel.actionErrorMessage
        ?? "The virtual machine could not start with automated guest setup."
      return false
    }

    clearSecrets()
    return true
  }

  func clearError() {
    errorMessage = nil
  }

  func clearSecrets() {
    password = ""
    passwordConfirmation = ""
  }
}
