import Foundation
import Observation

@MainActor
@Observable
final class ContainerInspectorModel {
  private(set) var inspection: ContainerInspection?
  private(set) var isLoading = false
  private(set) var errorMessage: String?

  let containerID: String
  private let service: any ContainerManaging

  init(containerID: String, service: any ContainerManaging) {
    self.containerID = containerID
    self.service = service
  }

  func load() async {
    guard !isLoading else { return }
    isLoading = true
    errorMessage = nil
    defer { isLoading = false }

    do {
      inspection = try await service.inspectContainer(id: containerID)
    } catch {
      errorMessage = error.localizedDescription
    }
  }
}
