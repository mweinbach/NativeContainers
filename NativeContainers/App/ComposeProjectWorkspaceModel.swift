import Foundation
import Observation

@MainActor
@Observable
final class ComposeProjectWorkspaceModel {
  var action: ComposeProjectLifecycleAction = .up {
    didSet {
      if action != .down {
        removeVolumes = false
        removeOrphans = false
      }
      invalidateReview()
    }
  }
  var projectName = "" {
    didSet { invalidateReview() }
  }
  var profilesText = "" {
    didSet { invalidateReview() }
  }
  var pullPolicy: ComposeProjectPullPolicy = .never {
    didSet { invalidateReview() }
  }
  var removeOrphans = false {
    didSet { invalidateReview() }
  }
  var removeVolumes = false {
    didSet { invalidateReview() }
  }
  var killStuckContainers = true {
    didSet { invalidateReview() }
  }

  private(set) var selectedDirectoryURL: URL?
  private(set) var inputRequirements: ComposeProjectInputRequirements?
  private(set) var inputValues: [String: String] = [:]
  private(set) var plan: ComposeProjectPlan?
  private(set) var isReviewing = false
  private(set) var isExecuting = false
  private(set) var isLoadingRecoveries = false
  private(set) var executionResult: ComposeProjectExecutionResult?
  private(set) var pendingRecoveries: [ComposeOperationRecoverySnapshot] = []
  private(set) var errorMessage: String?

  @ObservationIgnored
  private let service: any ComposeProjectLifecycleManaging
  @ObservationIgnored
  private let didMutate: @MainActor @Sendable () async -> Void

  init(
    service: any ComposeProjectLifecycleManaging,
    initialPlan: ComposeProjectPlan? = nil,
    didMutate: @escaping @MainActor @Sendable () async -> Void = {}
  ) {
    self.service = service
    self.didMutate = didMutate
    plan = initialPlan
  }

  var profiles: [String] {
    let separators = CharacterSet.whitespacesAndNewlines.union(
      CharacterSet(charactersIn: ",")
    )
    return Array(
      Set(
        profilesText
          .components(separatedBy: separators)
          .filter { !$0.isEmpty }
      )
    ).sorted(by: composeStringOrder)
  }

  var canReview: Bool {
    let requiredInputsArePresent =
      inputRequirements?.requiredEnvironmentVariables.allSatisfy {
        inputValues[$0] != nil
      } ?? true
    return selectedDirectoryURL != nil
      && isValidComposeProjectName(projectName)
      && profiles.allSatisfy(isValidComposeProfileName)
      && requiredInputsArePresent
      && !isReviewing
      && !isExecuting
  }

  var canExecute: Bool {
    plan?.canExecute == true
      && executionResult == nil
      && !isReviewing
      && !isExecuting
      && pendingRecoveries.isEmpty
  }

  var sourceDisplayName: String {
    selectedDirectoryURL?.lastPathComponent ?? "No project folder selected"
  }

  func begin(projectName suggestedProjectName: String? = nil) {
    action = suggestedProjectName == nil ? .up : .down
    projectName = suggestedProjectName ?? ""
    profilesText = ""
    pullPolicy = .never
    removeOrphans = false
    removeVolumes = false
    killStuckContainers = true
    selectedDirectoryURL = nil
    inputRequirements = nil
    inputValues = [:]
    plan = nil
    executionResult = nil
    errorMessage = nil
  }

  func selectDirectory(_ directoryURL: URL) {
    selectedDirectoryURL = directoryURL
    if projectName.isEmpty {
      projectName = Self.suggestedProjectName(from: directoryURL.lastPathComponent)
    } else {
      invalidateReview()
    }
  }

  func review() async {
    guard let selectedDirectoryURL else {
      errorMessage = "Choose the project folder that contains one conventional Compose file."
      return
    }

    let options = ComposeProjectReviewOptions(
      action: action,
      projectName: projectName,
      profiles: profiles,
      pullPolicy: pullPolicy,
      removeOrphans: removeOrphans,
      removeVolumes: removeVolumes,
      killStuckContainers: killStuckContainers
    )
    let previousPlanID = plan?.id
    isReviewing = true
    plan = nil
    executionResult = nil
    errorMessage = nil
    defer { isReviewing = false }
    if let previousPlanID {
      await service.discardReview(planID: previousPlanID)
    }

    do {
      let requirements: ComposeProjectInputRequirements
      if let inputRequirements {
        requirements = inputRequirements
      } else {
        requirements = try await service.discoverInputRequirements(
          directoryURL: selectedDirectoryURL,
          options: options
        )
        inputRequirements = requirements
        inputValues = [:]
        guard requirements.requiredEnvironmentVariables.isEmpty else { return }
      }
      defer {
        inputRequirements = nil
        inputValues = [:]
      }
      plan = try await service.review(
        directoryURL: selectedDirectoryURL,
        options: options,
        inputs: ComposeProjectReviewInputs(
          requirementsID: requirements.id,
          environmentValues: inputValues
        )
      )
    } catch is CancellationError {
      errorMessage = "Compose review was cancelled."
    } catch {
      errorMessage = error.localizedDescription
    }
  }

  func inputValue(for variable: String) -> String {
    inputValues[variable] ?? ""
  }

  func setInputValue(_ value: String, for variable: String) {
    guard inputRequirements?.requiredEnvironmentVariables.contains(variable) == true else {
      return
    }
    inputValues[variable] = value
    plan = nil
    executionResult = nil
    errorMessage = nil
  }

  func execute() async {
    guard let plan, plan.canExecute else {
      errorMessage = "Review a Compose operation with no blockers before execution."
      return
    }
    guard pendingRecoveries.isEmpty else {
      errorMessage = "Review and discard the pending Compose recovery record first."
      return
    }
    isExecuting = true
    executionResult = nil
    errorMessage = nil
    defer { isExecuting = false }

    do {
      executionResult = try await service.execute(plan)
      await didMutate()
      await loadRecoveries()
    } catch is CancellationError {
      await service.discardReview(planID: plan.id)
      self.plan = nil
      errorMessage =
        "Compose execution was cancelled. Reconcile the pending recovery record before another mutation."
      await loadRecoveries()
    } catch {
      await service.discardReview(planID: plan.id)
      self.plan = nil
      errorMessage = error.localizedDescription
      await loadRecoveries()
    }
  }

  func loadRecoveries() async {
    guard !isLoadingRecoveries else { return }
    isLoadingRecoveries = true
    defer { isLoadingRecoveries = false }
    do {
      pendingRecoveries = try await service.pendingRecoverySnapshots()
    } catch is CancellationError {
      return
    } catch {
      errorMessage = error.localizedDescription
    }
  }

  func discardRecoveryAfterReview(operationID: UUID) async {
    do {
      try await service.discardRecoveryAfterReview(operationID: operationID)
      await loadRecoveries()
    } catch is CancellationError {
      return
    } catch {
      errorMessage = error.localizedDescription
    }
  }

  func clearError() {
    errorMessage = nil
  }

  func discardPendingInputReview() async {
    let requirementsID = inputRequirements?.id
    let planID = plan?.id
    inputRequirements = nil
    inputValues = [:]
    plan = nil
    if let requirementsID {
      await service.discardInputRequirements(requirementsID)
    }
    if let planID {
      await service.discardReview(planID: planID)
    }
  }

  private func invalidateReview() {
    let requirementsID = inputRequirements?.id
    let planID = plan?.id
    inputRequirements = nil
    inputValues = [:]
    plan = nil
    executionResult = nil
    errorMessage = nil
    if let requirementsID {
      Task {
        await service.discardInputRequirements(requirementsID)
      }
    }
    if let planID {
      Task {
        await service.discardReview(planID: planID)
      }
    }
  }

  private static func suggestedProjectName(from directoryName: String) -> String {
    let lowered = directoryName.lowercased()
    var result = ""
    var lastWasSeparator = false
    for byte in lowered.utf8 {
      let isAllowed =
        (byte >= 97 && byte <= 122)
        || (byte >= 48 && byte <= 57)
        || byte == 45
        || byte == 95
      if isAllowed {
        result.append(Character(UnicodeScalar(byte)))
        lastWasSeparator = false
      } else if !result.isEmpty, !lastWasSeparator {
        result.append("-")
        lastWasSeparator = true
      }
    }
    while result.last == "-" {
      result.removeLast()
    }
    return isValidComposeProjectName(result) ? result : ""
  }
}
