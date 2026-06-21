import Foundation
import Observation

@MainActor
@Observable
final class ComposeProjectWorkspaceModel {
  var action: ComposeProjectLifecycleAction = .up {
    didSet {
      if action == .up {
        removeVolumes = false
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

  private(set) var selectedDirectoryURL: URL?
  private(set) var plan: ComposeProjectPlan?
  private(set) var isReviewing = false
  private(set) var errorMessage: String?

  @ObservationIgnored
  private let service: any ComposeProjectLifecycleManaging

  init(
    service: any ComposeProjectLifecycleManaging,
    initialPlan: ComposeProjectPlan? = nil
  ) {
    self.service = service
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
    selectedDirectoryURL != nil
      && isValidComposeProjectName(projectName)
      && profiles.allSatisfy(isValidComposeProfileName)
      && !isReviewing
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
    selectedDirectoryURL = nil
    plan = nil
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
      removeVolumes: removeVolumes
    )
    isReviewing = true
    plan = nil
    errorMessage = nil
    defer { isReviewing = false }

    do {
      plan = try await service.review(
        directoryURL: selectedDirectoryURL,
        options: options
      )
    } catch is CancellationError {
      errorMessage = "Compose review was cancelled."
    } catch {
      errorMessage = error.localizedDescription
    }
  }

  func clearError() {
    errorMessage = nil
  }

  private func invalidateReview() {
    plan = nil
    errorMessage = nil
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
