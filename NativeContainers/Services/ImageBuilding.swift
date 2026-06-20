import Foundation

typealias ImageBuildProgressHandler = @Sendable (ImageBuildProgress) async -> Void

protocol ImageBuilding: Sendable {
  func prepareBuild(
    _ request: ImageBuildRequest,
    progress: @escaping ImageBuildProgressHandler
  ) async throws -> ImageBuildPlan
  func build(
    _ plan: ImageBuildPlan,
    authorization: ImageBuildAuthorization,
    progress: @escaping ImageBuildProgressHandler
  ) async throws -> ImageBuildResult
  func discardBuild(_ plan: ImageBuildPlan) async
}

extension ImageBuilding {
  func prepareBuild(
    _ request: ImageBuildRequest,
    progress: @escaping ImageBuildProgressHandler
  ) async throws -> ImageBuildPlan {
    throw ImageBuildError.unsupported
  }

  func build(
    _ plan: ImageBuildPlan,
    authorization: ImageBuildAuthorization,
    progress: @escaping ImageBuildProgressHandler
  ) async throws -> ImageBuildResult {
    throw ImageBuildError.unsupported
  }

  func discardBuild(_ plan: ImageBuildPlan) async {}
}
