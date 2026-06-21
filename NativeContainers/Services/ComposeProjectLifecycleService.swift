import Foundation

protocol ComposeProjectLifecycleManaging: Sendable {
  func review(
    directoryURL: URL,
    options: ComposeProjectReviewOptions
  ) async throws -> ComposeProjectPlan

  func execute(_ plan: ComposeProjectPlan) async throws -> ComposeProjectExecutionResult
}

actor ComposeProjectLifecycleService: ComposeProjectLifecycleManaging {
  private let sourceAccess: any ComposeProjectSourceAccessing
  private let configRenderer: any ComposeConfigRendering
  private let desiredStateDecoder: any ComposeDesiredStateDecoding
  private let planner: any ComposeLifecyclePlanning
  private let inventory: any ContainerInventoryLoading

  init(
    sourceAccess: any ComposeProjectSourceAccessing = FileComposeProjectSourceService(),
    configRenderer: any ComposeConfigRendering,
    desiredStateDecoder: any ComposeDesiredStateDecoding = ComposeDesiredStateDecoder(),
    planner: any ComposeLifecyclePlanning = ComposeLifecyclePlanner(),
    inventory: any ContainerInventoryLoading
  ) {
    self.sourceAccess = sourceAccess
    self.configRenderer = configRenderer
    self.desiredStateDecoder = desiredStateDecoder
    self.planner = planner
    self.inventory = inventory
  }

  func review(
    directoryURL: URL,
    options: ComposeProjectReviewOptions
  ) async throws -> ComposeProjectPlan {
    try validate(options)
    let lease = try await sourceAccess.acquire(directoryURL: directoryURL)
    let rendered: ComposeRenderedConfiguration
    let desiredReview: ComposeDesiredStateReview

    do {
      try await sourceAccess.revalidate(lease)
      let first = try await configRenderer.render(source: lease, options: options)
      try await sourceAccess.revalidate(lease)
      let second = try await configRenderer.render(source: lease, options: options)
      try await sourceAccess.revalidate(lease)
      guard first == second else {
        throw ComposeProjectLifecycleError.configChangedDuringReview
      }
      rendered = second
      desiredReview = try desiredStateDecoder.decode(
        rendered: second,
        expectedProjectName: options.projectName
      )
      await sourceAccess.release(lease)
    } catch {
      await sourceAccess.release(lease)
      throw error
    }

    try Task.checkCancellation()
    let currentInventory = try await inventory.loadInventory()
    return planner.plan(
      source: lease.summary,
      rendered: rendered,
      review: desiredReview,
      options: options,
      inventory: currentInventory
    )
  }

  func execute(_ plan: ComposeProjectPlan) async throws -> ComposeProjectExecutionResult {
    throw ComposeProjectLifecycleError.unavailable(
      "This reviewed desired-state slice is intentionally read-only. Exact-ID mutation and crash-safe journaling are required before execution can be enabled."
    )
  }

  private func validate(_ options: ComposeProjectReviewOptions) throws {
    guard isValidComposeProjectName(options.projectName) else {
      throw ComposeProjectLifecycleError.invalidProjectName(options.projectName)
    }
    for profile in options.profiles where !isValidComposeProfileName(profile) {
      throw ComposeProjectLifecycleError.invalidProfileName(profile)
    }
    if options.action == .up, options.removeVolumes {
      throw ComposeProjectLifecycleError.unavailable(
        "Remove Volumes is only valid for a reviewed down operation."
      )
    }
  }
}

actor UnavailableComposeProjectLifecycleService: ComposeProjectLifecycleManaging {
  private let reason: String

  init(reason: String = "Compose desired-state review is unavailable.") {
    self.reason = reason
  }

  func review(
    directoryURL: URL,
    options: ComposeProjectReviewOptions
  ) async throws -> ComposeProjectPlan {
    throw ComposeProjectLifecycleError.unavailable(reason)
  }

  func execute(_ plan: ComposeProjectPlan) async throws -> ComposeProjectExecutionResult {
    throw ComposeProjectLifecycleError.unavailable(reason)
  }
}
