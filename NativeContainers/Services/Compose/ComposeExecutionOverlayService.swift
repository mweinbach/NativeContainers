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
