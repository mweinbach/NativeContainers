import CryptoKit
import Foundation

struct ComposeExecutionConfiguration: Equatable, Sendable {
  let data: Data
  let sha256: String
}

protocol ComposeExecutionOverlayPreparing: Sendable {
  func prepare(
    canonicalConfiguration: Data,
    plan: ComposeProjectPlan
  ) throws -> ComposeExecutionConfiguration

  func prepare(
    canonicalConfiguration: Data,
    plan: ComposeProjectPlan,
    reviewedInputs: ComposeReviewedInputPayload,
    stagedFileURLs: [String: URL]
  ) throws -> ComposeExecutionConfiguration
}

extension ComposeExecutionOverlayPreparing {
  func prepare(
    canonicalConfiguration: Data,
    plan: ComposeProjectPlan,
    reviewedInputs: ComposeReviewedInputPayload,
    stagedFileURLs: [String: URL]
  ) throws -> ComposeExecutionConfiguration {
    guard reviewedInputs == .empty, stagedFileURLs.isEmpty else {
      throw ComposeProjectLifecycleError.unavailable(
        "The configured execution overlay cannot stage reviewed Compose inputs."
      )
    }
    return try prepare(canonicalConfiguration: canonicalConfiguration, plan: plan)
  }
}

struct ComposeExecutionOverlayService: ComposeExecutionOverlayPreparing {
  private typealias JSONObject = [String: Any]

  private let canonicalModelValidator: any ComposeCanonicalModelValidating

  init(
    canonicalModelValidator: any ComposeCanonicalModelValidating =
      ComposeCanonicalModelValidator()
  ) {
    self.canonicalModelValidator = canonicalModelValidator
  }

  func prepare(
    canonicalConfiguration: Data,
    plan: ComposeProjectPlan
  ) throws -> ComposeExecutionConfiguration {
    try prepare(
      canonicalConfiguration: canonicalConfiguration,
      plan: plan,
      reviewedInputs: .empty,
      stagedFileURLs: [:]
    )
  }

  func prepare(
    canonicalConfiguration: Data,
    plan: ComposeProjectPlan,
    reviewedInputs: ComposeReviewedInputPayload,
    stagedFileURLs: [String: URL]
  ) throws -> ComposeExecutionConfiguration {
    guard
      plan.options.action == .up,
      sha256(canonicalConfiguration) == plan.fullConfigurationSHA256
    else {
      throw ComposeProjectLifecycleError.stalePlan
    }

    let allowlistIssues = try canonicalModelValidator.reviewIssues(
      fullConfiguration: canonicalConfiguration,
      activeConfiguration: canonicalConfiguration,
      projectName: plan.options.projectName
    )
    guard allowlistIssues.isEmpty else {
      throw ComposeProjectLifecycleError.configOutputInvalid(
        "The reviewed model is outside the supported execution allowlist."
      )
    }

    var project = try decodeObject(canonicalConfiguration)
    guard
      project["name"] as? String == plan.options.projectName,
      let services = project["services"] as? JSONObject,
      Set(services.keys) == Set(plan.desiredState.declaredServiceNames)
    else {
      throw ComposeProjectLifecycleError.stalePlan
    }

    try validateActiveResourceActions(plan)
    project["volumes"] = try overlaidResources(
      object(project["volumes"]),
      desired: plan.desiredState.volumes
    )
    project["networks"] = try overlaidResources(
      object(project["networks"]),
      desired: plan.desiredState.networks
    )
    project["services"] = try overlaidServices(
      services,
      desired: plan.desiredState.activeServices
    )
    try overlayInputSources(
      project: &project,
      reviewedInputs: reviewedInputs,
      stagedFileURLs: stagedFileURLs
    )
    project = escapeInterpolation(in: project) as! JSONObject

    let data: Data
    do {
      data = try JSONSerialization.data(
        withJSONObject: project,
        options: [.sortedKeys, .withoutEscapingSlashes]
      )
    } catch {
      throw ComposeProjectLifecycleError.configOutputInvalid(
        "The external-resource execution overlay could not be encoded."
      )
    }
    return ComposeExecutionConfiguration(data: data, sha256: sha256(data))
  }

  private func escapeInterpolation(in value: Any) -> Any {
    if let string = value as? String {
      return string.replacingOccurrences(of: "$", with: "$$")
    }
    if let array = value as? [Any] {
      return array.map { escapeInterpolation(in: $0) }
    }
    if let object = value as? JSONObject {
      return object.mapValues { escapeInterpolation(in: $0) }
    }
    return value
  }

  private func overlaidServices(
    _ services: JSONObject,
    desired: [ComposeDesiredService]
  ) throws -> JSONObject {
    let desiredByName = Dictionary(
      uniqueKeysWithValues: desired.map { ($0.name, $0) }
    )
    return try services.reduce(into: JSONObject()) { result, entry in
      guard var service = entry.value as? JSONObject else {
        throw ComposeProjectLifecycleError.stalePlan
      }
      if let desiredService = desiredByName[entry.key],
        let inputSeal = desiredService.inputSeal,
        let configurationHash = desiredService.configurationHash
      {
        var labels = service["labels"] as? JSONObject ?? [:]
        guard !labels.keys.contains(where: { $0.hasPrefix(ComposeLabelKey.nativePrefix) }) else {
          throw ComposeProjectLifecycleError.configOutputInvalid(
            "A service label collides with the NativeContainers review boundary."
          )
        }
        labels[ComposeLabelKey.inputSeal] = inputSeal
        labels[ComposeLabelKey.reviewedConfigHash] = configurationHash
        service["labels"] = labels
      }
      result[entry.key] = service
    }
  }

  private func overlayInputSources(
    project: inout JSONObject,
    reviewedInputs: ComposeReviewedInputPayload,
    stagedFileURLs: [String: URL]
  ) throws {
    let expectedFileIDs = Set(reviewedInputs.files.map(\.id))
    guard Set(stagedFileURLs.keys) == expectedFileIDs else {
      throw ComposeProjectLifecycleError.stalePlan
    }
    for kind in [ComposeProjectInputKind.config, .secret] {
      let key = kind == .config ? "configs" : "secrets"
      var resources = project[key] as? JSONObject ?? [:]
      for binding in reviewedInputs.bindings where binding.kind == kind {
        guard var resource = resources[binding.name] as? JSONObject else {
          throw ComposeProjectLifecycleError.stalePlan
        }
        switch binding.sourceKind {
        case .file:
          guard let fileID = binding.stagedFileID,
            let url = stagedFileURLs[fileID]
          else {
            throw ComposeProjectLifecycleError.stalePlan
          }
          resource["file"] = url.nativeContainersPOSIXPath
        case .environment, .literal:
          guard binding.stagedFileID == nil else {
            throw ComposeProjectLifecycleError.stalePlan
          }
        }
        resources[binding.name] = resource
      }
      if project[key] != nil { project[key] = resources }
    }
  }

  private func validateActiveResourceActions(_ plan: ComposeProjectPlan) throws {
    var volumeActions: [String: ComposeProjectVolumeAction] = [:]
    for action in plan.volumeActions {
      guard volumeActions.updateValue(action, forKey: action.logicalName) == nil else {
        throw ComposeProjectLifecycleError.observedStateChanged
      }
    }
    var networkActions: [String: ComposeProjectNetworkAction] = [:]
    for action in plan.networkActions {
      guard networkActions.updateValue(action, forKey: action.logicalName) == nil else {
        throw ComposeProjectLifecycleError.observedStateChanged
      }
    }

    for resource in plan.desiredState.activeResources {
      switch resource.kind {
      case .volume:
        guard
          let action = volumeActions[resource.logicalName],
          action.runtimeName == resource.runtimeName,
          actionMatches(
            resource,
            operation: action.operation,
            hasIdentity: action.expectedIdentity != nil
          )
        else {
          throw ComposeProjectLifecycleError.observedStateChanged
        }
      case .network:
        guard
          let action = networkActions[resource.logicalName],
          action.runtimeName == resource.runtimeName,
          actionMatches(
            resource,
            operation: action.operation,
            hasIdentity: action.expectedIdentity != nil
          )
        else {
          throw ComposeProjectLifecycleError.observedStateChanged
        }
      }
    }
  }

  private func actionMatches(
    _ resource: ComposeDesiredResource,
    operation: ComposeProjectResourceOperation,
    hasIdentity: Bool
  ) -> Bool {
    if resource.isExternal {
      return operation == .useExternal && hasIdentity
    }
    return operation == (hasIdentity ? .reuseManaged : .createManaged)
  }

  private func overlaidResources(
    _ resources: JSONObject,
    desired: [ComposeDesiredResource]
  ) throws -> JSONObject {
    let desiredByLogicalName = Dictionary(
      desired.map { ($0.logicalName, $0) },
      uniquingKeysWith: { first, _ in first }
    )
    guard
      desiredByLogicalName.count == desired.count,
      Set(resources.keys) == Set(desiredByLogicalName.keys)
    else {
      throw ComposeProjectLifecycleError.stalePlan
    }

    return try resources.reduce(into: JSONObject()) { result, element in
      guard
        element.value is JSONObject,
        let resource = desiredByLogicalName[element.key]
      else {
        throw ComposeProjectLifecycleError.stalePlan
      }
      result[element.key] = [
        "external": true,
        "name": resource.runtimeName,
      ]
    }
  }

  private func decodeObject(_ data: Data) throws -> JSONObject {
    do {
      guard let object = try JSONSerialization.jsonObject(with: data) as? JSONObject else {
        throw ComposeProjectLifecycleError.configOutputInvalid(
          "The canonical model was not a JSON object."
        )
      }
      return object
    } catch let error as ComposeProjectLifecycleError {
      throw error
    } catch {
      throw ComposeProjectLifecycleError.configOutputInvalid(
        "The canonical model was not valid JSON."
      )
    }
  }

  private func object(_ value: Any?) -> JSONObject {
    value as? JSONObject ?? [:]
  }

  private func sha256(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
  }
}
