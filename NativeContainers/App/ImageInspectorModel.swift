import Foundation
import Observation

struct ImageInspectionRefreshID: Hashable, Sendable {
  let reference: String
  let digest: String
  let inventoryRevision: Date?

  init(image: ImageRecord, inventoryRevision: Date?) {
    reference = image.reference
    digest = image.digest
    self.inventoryRevision = inventoryRevision
  }
}

@MainActor
@Observable
final class ImageInspectorModel {
  let reference: String
  private(set) var inspection: ImageInspection?
  private(set) var isLoading = false
  private(set) var errorMessage: String?

  private let service: any ImageManaging
  private var loadGeneration = 0

  init(reference: String, service: any ImageManaging) {
    self.reference = reference
    self.service = service
  }

  func load() async {
    loadGeneration += 1
    let generation = loadGeneration
    isLoading = true
    errorMessage = nil
    defer {
      if generation == loadGeneration {
        isLoading = false
      }
    }

    do {
      let inspection = try await service.inspectImage(reference: reference)
      try Task.checkCancellation()
      guard generation == loadGeneration else { return }
      self.inspection = inspection
    } catch is CancellationError {
      return
    } catch {
      guard generation == loadGeneration else { return }
      errorMessage = error.localizedDescription
    }
  }
}
