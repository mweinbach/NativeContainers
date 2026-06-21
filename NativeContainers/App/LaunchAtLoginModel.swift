import Observation

@MainActor
@Observable
final class LaunchAtLoginModel {
  private(set) var status: LaunchAtLoginStatus
  private(set) var isUpdating = false
  private(set) var errorMessage: String?

  private let service: any LaunchAtLoginManaging

  init(service: any LaunchAtLoginManaging) {
    self.service = service
    status = service.status()
  }

  var isEnabled: Bool {
    get { status.isRequested }
    set { setEnabled(newValue) }
  }

  func refresh() {
    status = service.status()
    errorMessage = nil
  }

  func setEnabled(_ enabled: Bool) {
    guard status.canChange, !isUpdating, enabled != status.isRequested else {
      return
    }

    isUpdating = true
    defer { isUpdating = false }

    do {
      status = try service.setEnabled(enabled)
      errorMessage = nil
    } catch {
      status = service.status()
      errorMessage = error.localizedDescription
    }
  }
}
