import Foundation
import ServiceManagement
import Testing

@testable import NativeContainers

@MainActor
struct LaunchAtLoginModelTests {
  @Test
  func systemStatusMappingIsComplete() {
    #expect(
      SMAppServiceLaunchAtLoginService.status(from: .notRegistered)
        == .notRegistered
    )
    #expect(
      SMAppServiceLaunchAtLoginService.status(from: .enabled)
        == .enabled
    )
    #expect(
      SMAppServiceLaunchAtLoginService.status(from: .requiresApproval)
        == .requiresApproval
    )
    #expect(
      SMAppServiceLaunchAtLoginService.status(from: .notFound)
        == .unavailable
    )
  }

  @Test
  func systemServiceRegistersOnceAndAcceptsApprovalRequired() throws {
    let registration = RecordingLoginItemRegistration(status: .notRegistered)
    registration.statusAfterRegister = .requiresApproval
    let service = SMAppServiceLaunchAtLoginService(registration: registration)

    let first = try service.setEnabled(true)
    let second = try service.setEnabled(true)

    #expect(first == .requiresApproval)
    #expect(second == .requiresApproval)
    #expect(registration.registerCount == 1)
    #expect(registration.unregisterCount == 0)
  }

  @Test
  func systemServiceUnregistersAnApprovalRequestOnce() throws {
    let registration = RecordingLoginItemRegistration(status: .requiresApproval)
    registration.statusAfterUnregister = .notRegistered
    let service = SMAppServiceLaunchAtLoginService(registration: registration)

    let first = try service.setEnabled(false)
    let second = try service.setEnabled(false)

    #expect(first == .notRegistered)
    #expect(second == .notRegistered)
    #expect(registration.registerCount == 0)
    #expect(registration.unregisterCount == 1)
  }

  @Test
  func systemServiceRejectsUnavailableAndUnconfirmedState() {
    let unavailable = RecordingLoginItemRegistration(status: .unavailable)
    let unavailableService = SMAppServiceLaunchAtLoginService(
      registration: unavailable
    )

    #expect(throws: (any Error).self) {
      try unavailableService.setEnabled(true)
    }
    #expect(unavailable.registerCount == 0)

    let unconfirmed = RecordingLoginItemRegistration(status: .notRegistered)
    let unconfirmedService = SMAppServiceLaunchAtLoginService(
      registration: unconfirmed
    )

    #expect(throws: (any Error).self) {
      try unconfirmedService.setEnabled(true)
    }
    #expect(unconfirmed.registerCount == 1)
  }

  @Test
  func initializesFromTheServiceAndKeepsApprovalRequestedOn() {
    let service = RecordingLaunchAtLoginService(status: .requiresApproval)
    let model = LaunchAtLoginModel(service: service)

    #expect(model.status == .requiresApproval)
    #expect(model.isEnabled)
    #expect(model.status.canChange)
    #expect(!model.isUpdating)
    #expect(model.errorMessage == nil)
  }

  @Test
  func enablingPublishesTheReturnedStatusAndIgnoresDuplicateWrites() {
    let service = RecordingLaunchAtLoginService(status: .notRegistered)
    service.nextStatus = .enabled
    let model = LaunchAtLoginModel(service: service)

    model.isEnabled = true
    model.isEnabled = true

    #expect(service.requests == [true])
    #expect(model.status == .enabled)
    #expect(model.isEnabled)
    #expect(model.errorMessage == nil)
  }

  @Test
  func disablingAnApprovalRequestUnregistersIt() {
    let service = RecordingLaunchAtLoginService(status: .requiresApproval)
    service.nextStatus = .notRegistered
    let model = LaunchAtLoginModel(service: service)

    model.isEnabled = false

    #expect(service.requests == [false])
    #expect(model.status == .notRegistered)
    #expect(!model.isEnabled)
  }

  @Test
  func failureReloadsAuthoritativeStatusAndPublishesTheError() {
    let service = RecordingLaunchAtLoginService(status: .notRegistered)
    service.operationError = ExpectedLaunchAtLoginError()
    let model = LaunchAtLoginModel(service: service)

    model.isEnabled = true

    #expect(service.requests == [true])
    #expect(model.status == .notRegistered)
    #expect(model.errorMessage == "Expected launch-at-login failure.")
    #expect(!model.isUpdating)
  }

  @Test
  func unavailableStatusCannotAttemptRegistration() {
    let service = RecordingLaunchAtLoginService(status: .unavailable)
    let model = LaunchAtLoginModel(service: service)

    model.isEnabled = true

    #expect(service.requests.isEmpty)
    #expect(model.status == .unavailable)
    #expect(!model.isEnabled)
  }
}

@MainActor
private final class RecordingLoginItemRegistration:
  MainApplicationLoginItemRegistering
{
  var status: LaunchAtLoginStatus
  var statusAfterRegister: LaunchAtLoginStatus?
  var statusAfterUnregister: LaunchAtLoginStatus?
  private(set) var registerCount = 0
  private(set) var unregisterCount = 0

  init(status: LaunchAtLoginStatus) {
    self.status = status
  }

  func register() {
    registerCount += 1
    if let statusAfterRegister {
      status = statusAfterRegister
    }
  }

  func unregister() {
    unregisterCount += 1
    if let statusAfterUnregister {
      status = statusAfterUnregister
    }
  }
}

@MainActor
private final class RecordingLaunchAtLoginService: LaunchAtLoginManaging {
  var currentStatus: LaunchAtLoginStatus
  var nextStatus: LaunchAtLoginStatus?
  var operationError: (any Error)?
  private(set) var requests: [Bool] = []

  init(status: LaunchAtLoginStatus) {
    currentStatus = status
  }

  func status() -> LaunchAtLoginStatus {
    currentStatus
  }

  func setEnabled(_ enabled: Bool) throws -> LaunchAtLoginStatus {
    requests.append(enabled)
    if let operationError {
      throw operationError
    }
    currentStatus = nextStatus ?? (enabled ? .enabled : .notRegistered)
    return currentStatus
  }
}

private struct ExpectedLaunchAtLoginError: LocalizedError {
  var errorDescription: String? {
    "Expected launch-at-login failure."
  }
}
