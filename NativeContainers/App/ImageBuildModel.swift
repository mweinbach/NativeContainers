import Foundation
import Observation

@MainActor
@Observable
final class ImageBuildModel {
  private(set) var plan: ImageBuildPlan?
  private(set) var result: ImageBuildResult?
  private(set) var progress: ImageBuildProgress?
  private(set) var errorMessage: String?
  private(set) var isPreparing = false
  private(set) var isBuilding = false

  private let service: any ImageBuilding
  private let didMutate: @MainActor @Sendable () async -> Void

  init(
    service: any ImageBuilding,
    didMutate: @escaping @MainActor @Sendable () async -> Void
  ) {
    self.service = service
    self.didMutate = didMutate
  }

  func prepare(_ request: ImageBuildRequest) async -> ImageBuildPlan? {
    guard !isWorking else { return nil }
    if let plan {
      await service.discardBuild(plan)
      self.plan = nil
    }
    isPreparing = true
    result = nil
    errorMessage = nil
    progress = nil
    defer { isPreparing = false }
    do {
      let prepared = try await service.prepareBuild(request) { update in
        await self.receive(update)
      }
      guard !Task.isCancelled else {
        await service.discardBuild(prepared)
        return nil
      }
      plan = prepared
      return prepared
    } catch is CancellationError {
      return nil
    } catch {
      errorMessage = error.localizedDescription
      return nil
    }
  }

  func execute(
    _ reviewedPlan: ImageBuildPlan? = nil,
    authorization: ImageBuildAuthorization
  ) async -> Bool {
    guard let reviewedPlan = reviewedPlan ?? plan, !isWorking else { return false }
    isBuilding = true
    errorMessage = nil
    result = nil
    defer {
      isBuilding = false
      plan = nil
    }
    do {
      result = try await service.build(
        reviewedPlan,
        authorization: authorization
      ) { update in
        await self.receive(update)
      }
      if reviewedPlan.output.kind == .imageStore {
        await didMutate()
      }
      return true
    } catch is CancellationError {
      errorMessage =
        "The build was cancelled before a final output was promised. Any already committed output is retained."
      if reviewedPlan.output.kind == .imageStore {
        await didMutate()
      }
      return false
    } catch {
      errorMessage = error.localizedDescription
      if reviewedPlan.output.kind == .imageStore {
        await didMutate()
      }
      return false
    }
  }

  func discardPlan() async {
    guard let plan, !isWorking else { return }
    self.plan = nil
    await service.discardBuild(plan)
  }

  func clearResult() {
    result = nil
    errorMessage = nil
    progress = nil
  }

  var isWorking: Bool { isPreparing || isBuilding }

  private func receive(_ update: ImageBuildProgress) {
    progress = update
  }
}
