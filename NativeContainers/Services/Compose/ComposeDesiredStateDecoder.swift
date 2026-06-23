import Foundation

protocol ComposeDesiredStateDecoding: Sendable {
  func decode(
    rendered: ComposeRenderedConfiguration,
    expectedProjectName: String,
    serviceInputSeals: [String: String]
  ) throws -> ComposeDesiredStateReview
}

extension ComposeDesiredStateDecoding {
  func decode(
    rendered: ComposeRenderedConfiguration,
    expectedProjectName: String
  ) throws -> ComposeDesiredStateReview {
    try decode(
      rendered: rendered,
      expectedProjectName: expectedProjectName,
      serviceInputSeals: [:]
    )
  }
}

struct ComposeDesiredStateDecoder: ComposeDesiredStateDecoding {
  private typealias JSONObject = [String: Any]

  private let canonicalModelValidator: any ComposeCanonicalModelValidating
  private let allowsBlockedLocalInputExecutionForTesting: Bool

  init(
    canonicalModelValidator: any ComposeCanonicalModelValidating =
      ComposeCanonicalModelValidator(),
    allowsBlockedLocalInputExecutionForTesting: Bool = false
  ) {
    self.canonicalModelValidator = canonicalModelValidator
    self.allowsBlockedLocalInputExecutionForTesting =
      allowsBlockedLocalInputExecutionForTesting
  }

  func decode(
    rendered: ComposeRenderedConfiguration,
    expectedProjectName: String,
    serviceInputSeals: [String: String]
  ) throws -> ComposeDesiredStateReview {
    let full = try decodeObject(rendered.fullConfiguration)
    let active = try decodeObject(rendered.activeConfiguration)
    try validateProjectName(full, expected: expectedProjectName)
    try validateProjectName(active, expected: expectedProjectName)

    guard
      let fullServices = full["services"] as? JSONObject,
      let activeServices = active["services"] as? JSONObject
    else {
      throw ComposeProjectLifecycleError.configOutputInvalid(
        "The canonical model did not contain service dictionaries."
      )
    }

    var issues = try canonicalModelValidator.reviewIssues(
      fullConfiguration: rendered.fullConfiguration,
      activeConfiguration: rendered.activeConfiguration,
      projectName: expectedProjectName
    )
    let declaredServiceNames = fullServices.keys.sorted(by: composeStringOrder)
    guard Set(rendered.serviceConfigurationHashes.keys) == Set(declaredServiceNames) else {
      throw ComposeProjectLifecycleError.configOutputInvalid(
        "The service configuration hashes did not match the full service model."
      )
    }
    let fullServiceNames = Set(declaredServiceNames)
    guard Set(serviceInputSeals.keys).isSubset(of: fullServiceNames),
      serviceInputSeals.values.allSatisfy(isLowercaseSHA256)
    else {
      throw ComposeProjectLifecycleError.configOutputInvalid(
        "The reviewed Compose input seals did not match the service model."
      )
    }
    let serviceDependencies = declaredServiceNames.reduce(
      into: [String: [String]]()
    ) { result, serviceName in
      guard let service = fullServices[serviceName] as? JSONObject else {
        result[serviceName] = []
        return
      }
      result[serviceName] = dependencyNames(
        service["depends_on"],
        serviceName: serviceName,
        fullServiceNames: fullServiceNames,
        issues: &issues
      )
    }
    detectDependencyCycles(
      serviceDependencies,
      issues: &issues
    )
    let desiredServices = activeServices.keys.sorted(by: composeStringOrder).compactMap {
      serviceName in
      parseService(
        name: serviceName,
        value: activeServices[serviceName],
        dependencies: serviceDependencies[serviceName] ?? [],
        configurationHash: rendered.serviceConfigurationHashes[serviceName],
        inputSeal: serviceInputSeals[serviceName],
        issues: &issues
      )
    }

    let fullVolumes = object(full["volumes"])
    let activeVolumes = Set(object(active["volumes"]).keys)
    let volumes = parseResources(
      kind: .volume,
      full: fullVolumes,
      activeNames: activeVolumes,
      projectName: expectedProjectName,
      issues: &issues
    )

    let fullNetworks = object(full["networks"])
    let activeNetworks = Set(object(active["networks"]).keys)
    let networks = parseResources(
      kind: .network,
      full: fullNetworks,
      activeNames: activeNetworks,
      projectName: expectedProjectName,
      issues: &issues
    )

    let state = ComposeDesiredState(
      projectName: expectedProjectName,
      declaredServiceNames: declaredServiceNames,
      serviceDependencies: serviceDependencies,
      activeServices: desiredServices,
      volumes: volumes,
      networks: networks
    )
    return ComposeDesiredStateReview(
      desiredState: state,
      issues: issues.sorted(by: issueOrder)
    )
  }

  private func parseService(
    name: String,
    value: Any?,
    dependencies: [String],
    configurationHash: String?,
    inputSeal: String?,
    issues: inout [ComposeProjectReviewIssue]
  ) -> ComposeDesiredService? {
    guard isValidLogicalName(name), let service = value as? JSONObject else {
      issues.append(
        blocker(
          .invalidModel,
          subject: name,
          message: "The service name or canonical service object is invalid."
        )
      )
      return nil
    }

    let imageReference = (service["image"] as? String) ?? ""
    if imageReference.isEmpty {
      issues.append(
        blocker(
          .missingImage,
          subject: name,
          message: "The service must use a reviewed image reference; builds are not supported."
        )
      )
    }

    detectUnsupportedFeatures(in: service, serviceName: name, issues: &issues)
    let replicaCount = replicas(in: service, serviceName: name, issues: &issues)
    if replicaCount > 1, service["container_name"] is String {
      issues.append(
        blocker(
          .invalidModel,
          subject: name,
          message: "A service with container_name cannot have more than one replica."
        )
      )
    }

    let profiles = stringArray(service["profiles"])
    for profile in profiles where !isValidComposeProfileName(profile) {
      issues.append(
        blocker(
          .invalidModel,
          subject: name,
          message: "The service contains an invalid profile name."
        )
      )
    }

    var volumeNames: [String] = []
    if let rawMounts = service["volumes"] {
      guard let mounts = rawMounts as? [Any] else {
        issues.append(
          blocker(
            .invalidModel,
            subject: name,
            message: "The canonical volume mount list is invalid."
          )
        )
        return nil
      }
      for mount in mounts {
        guard
          let mount = mount as? JSONObject,
          mount["type"] as? String == "volume",
          let source = mount["source"] as? String,
          !source.isEmpty
        else {
          issues.append(
            blocker(
              .unsupportedFeature,
              subject: name,
              message: "Only declared named-volume mounts are supported."
            )
          )
          continue
        }
        volumeNames.append(source)
      }
    }

    var networkNames: [String] = []
    if let rawNetworks = service["networks"] {
      guard let networks = rawNetworks as? JSONObject else {
        issues.append(
          blocker(
            .invalidModel,
            subject: name,
            message: "The canonical network attachment model is invalid."
          )
        )
        return nil
      }
      networkNames = networks.keys.sorted(by: composeStringOrder)
      for networkName in networkNames {
        if let attachment = networks[networkName] as? JSONObject,
          !stringArray(attachment["aliases"]).isEmpty
        {
          issues.append(
            blocker(
              .unsupportedFeature,
              subject: name,
              message: "Custom network aliases are not supported."
            )
          )
        }
      }
    }

    let publishedPortCount: Int
    if let ports = service["ports"] as? [Any] {
      publishedPortCount = ports.count
    } else if service["ports"] == nil {
      publishedPortCount = 0
    } else {
      publishedPortCount = 0
      issues.append(
        blocker(
          .invalidModel,
          subject: name,
          message: "The canonical published-port model is invalid."
        )
      )
    }

    return ComposeDesiredService(
      name: name,
      imageReference: imageReference,
      replicaCount: replicaCount,
      profiles: profiles.sorted(by: composeStringOrder),
      dependencyNames: dependencies,
      configurationHash: configurationHash,
      inputSeal: inputSeal,
      volumeNames: Array(Set(volumeNames)).sorted(by: composeStringOrder),
      networkNames: networkNames,
      publishedPortCount: publishedPortCount
    )
  }

  private func detectUnsupportedFeatures(
    in service: JSONObject,
    serviceName: String,
    issues: inout [ComposeProjectReviewIssue]
  ) {
    let unsupportedPresence = [
      "build",
      "healthcheck",
      "provider",
      "develop",
      "credential_spec",
      "gpus",
      "runtime",
      "volumes_from",
      "links",
      "external_links",
      "env_file",
    ]
    for key in unsupportedPresence where hasMeaningfulValue(service[key]) {
      issues.append(
        blocker(
          .unsupportedFeature,
          subject: serviceName,
          message: "The service uses unsupported \(key) configuration."
        )
      )
    }

    if !allowsBlockedLocalInputExecutionForTesting {
      for key in ["configs", "secrets"] where hasMeaningfulValue(service[key]) {
        issues.append(
          blocker(
            .unsupportedFeature,
            subject: serviceName,
            message:
              "Service \(key) remain blocked by signed Socktainer 1.0.0: file sources require unsupported host-file bind mounts, while injected sources require archive access before the container root filesystem is available."
          )
        )
      }
    }

    if let restart = service["restart"] as? String, !restart.isEmpty {
      issues.append(
        blocker(
          .unsupportedFeature,
          subject: serviceName,
          message: "Restart policies are not supported."
        )
      )
    }

    for key in [
      "privileged",
      "devices",
      "cap_add",
      "cap_drop",
      "security_opt",
      "sysctls",
      "network_mode",
      "ipc",
      "pid",
      "uts",
      "userns_mode",
      "shm_size",
    ] where hasMeaningfulValue(service[key]) {
      issues.append(
        blocker(
          .unsupportedFeature,
          subject: serviceName,
          message: "The service uses unsupported host/runtime isolation configuration."
        )
      )
    }
  }

  private func dependencyNames(
    _ value: Any?,
    serviceName: String,
    fullServiceNames: Set<String>,
    issues: inout [ComposeProjectReviewIssue]
  ) -> [String] {
    guard let value else { return [] }
    guard let dependencies = value as? JSONObject else {
      issues.append(
        blocker(
          .invalidModel,
          subject: serviceName,
          message: "The dependency model is invalid."
        )
      )
      return []
    }

    var names: [String] = []
    for dependencyName in dependencies.keys.sorted(by: composeStringOrder) {
      guard fullServiceNames.contains(dependencyName) else {
        issues.append(
          blocker(
            .invalidModel,
            subject: serviceName,
            message: "A required service dependency is missing from the full model."
          )
        )
        continue
      }
      names.append(dependencyName)
      guard let dependency = dependencies[dependencyName] as? JSONObject else {
        issues.append(
          blocker(
            .invalidModel,
            subject: serviceName,
            message: "The canonical dependency configuration is invalid."
          )
        )
        continue
      }
      let condition = dependency["condition"] as? String ?? "service_started"
      let restart = dependency["restart"] as? Bool ?? false
      let required = dependency["required"] as? Bool ?? true
      if condition != "service_started" || restart || !required {
        issues.append(
          blocker(
            .unsupportedFeature,
            subject: serviceName,
            message:
              "Only required service_started dependencies without restart propagation are supported."
          )
        )
      }
    }
    return names
  }

  private func detectDependencyCycles(
    _ dependencies: [String: [String]],
    issues: inout [ComposeProjectReviewIssue]
  ) {
    enum VisitState {
      case visiting
      case visited
    }
    var states: [String: VisitState] = [:]
    var cycleMembers: Set<String> = []

    func visit(_ service: String, stack: [String]) {
      if states[service] == .visiting {
        cycleMembers.formUnion(stack.drop(while: { $0 != service }))
        cycleMembers.insert(service)
        return
      }
      guard states[service] == nil else { return }
      states[service] = .visiting
      for dependency in dependencies[service] ?? [] {
        visit(dependency, stack: stack + [service])
      }
      states[service] = .visited
    }

    for service in dependencies.keys.sorted(by: composeStringOrder) {
      visit(service, stack: [])
    }
    for service in cycleMembers.sorted(by: composeStringOrder) {
      issues.append(
        blocker(
          .invalidModel,
          subject: service,
          message: "The service dependency graph contains a cycle."
        )
      )
    }
  }

  private func replicas(
    in service: JSONObject,
    serviceName: String,
    issues: inout [ComposeProjectReviewIssue]
  ) -> Int {
    let scale = integer(service["scale"])
    let deployReplicas = (service["deploy"] as? JSONObject).flatMap {
      integer($0["replicas"])
    }
    if let scale, let deployReplicas, scale != deployReplicas {
      issues.append(
        blocker(
          .invalidModel,
          subject: serviceName,
          message: "scale and deploy.replicas disagree."
        )
      )
    }

    let value = scale ?? deployReplicas ?? 1
    guard value >= 0, value <= 10_000 else {
      issues.append(
        blocker(
          .invalidModel,
          subject: serviceName,
          message: "The desired replica count is outside the supported range."
        )
      )
      return max(0, min(value, 10_000))
    }
    return value
  }

  private func parseResources(
    kind: ComposeDesiredResourceKind,
    full: JSONObject,
    activeNames: Set<String>,
    projectName: String,
    issues: inout [ComposeProjectReviewIssue]
  ) -> [ComposeDesiredResource] {
    full.keys.sorted(by: composeStringOrder).compactMap { logicalName in
      guard
        isValidLogicalName(logicalName),
        let resource = full[logicalName] as? JSONObject
      else {
        issues.append(
          blocker(
            .invalidModel,
            subject: logicalName,
            message: "A canonical \(kind.rawValue) declaration is invalid."
          )
        )
        return nil
      }

      let external = resource["external"] as? Bool ?? false
      let runtimeName =
        (resource["name"] as? String)
        ?? (external ? logicalName : "\(projectName)_\(logicalName)")
      guard !runtimeName.isEmpty else {
        issues.append(
          blocker(
            .invalidModel,
            subject: logicalName,
            message: "The canonical \(kind.rawValue) has no runtime name."
          )
        )
        return nil
      }

      if let driver = resource["driver"] as? String {
        let supported =
          kind == .volume
          ? driver == "local"
          : driver == "bridge" || driver == "container-network-vmnet"
        if !supported {
          issues.append(
            blocker(
              .unsupportedFeature,
              subject: logicalName,
              message: "The requested \(kind.rawValue) driver is not supported."
            )
          )
        }
      }
      if hasMeaningfulValue(resource["driver_opts"]) {
        issues.append(
          blocker(
            .unsupportedFeature,
            subject: logicalName,
            message: "Custom \(kind.rawValue) driver options are not supported."
          )
        )
      }
      if kind == .network, hasMeaningfulValue(resource["ipam"]) {
        let ipam = resource["ipam"] as? JSONObject
        if ipam?.isEmpty != true {
          issues.append(
            blocker(
              .unsupportedFeature,
              subject: logicalName,
              message: "Custom network IPAM is not supported."
            )
          )
        }
      }

      return ComposeDesiredResource(
        kind: kind,
        logicalName: logicalName,
        runtimeName: runtimeName,
        isExternal: external,
        isActive: activeNames.contains(logicalName)
      )
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

  private func validateProjectName(
    _ object: JSONObject,
    expected: String
  ) throws {
    guard object["name"] as? String == expected else {
      throw ComposeProjectLifecycleError.configOutputInvalid(
        "The canonical project name changed."
      )
    }
  }

  private func object(_ value: Any?) -> JSONObject {
    value as? JSONObject ?? [:]
  }

  private func stringArray(_ value: Any?) -> [String] {
    (value as? [Any])?.compactMap { $0 as? String } ?? []
  }

  private func integer(_ value: Any?) -> Int? {
    guard let number = value as? NSNumber else { return nil }
    let type = String(cString: number.objCType)
    guard type != "c", number.doubleValue.rounded() == number.doubleValue else {
      return nil
    }
    return number.intValue
  }

  private func hasMeaningfulValue(_ value: Any?) -> Bool {
    switch value {
    case nil, is NSNull:
      false
    case let value as Bool:
      value
    case let value as String:
      !value.isEmpty && value != "private"
    case let value as [Any]:
      !value.isEmpty
    case let value as JSONObject:
      !value.isEmpty
    default:
      true
    }
  }

  private func blocker(
    _ code: ComposeProjectReviewIssueCode,
    subject: String,
    message: String
  ) -> ComposeProjectReviewIssue {
    ComposeProjectReviewIssue(
      severity: .blocker,
      code: code,
      subject: subject,
      message: message
    )
  }

  private func issueOrder(
    _ lhs: ComposeProjectReviewIssue,
    _ rhs: ComposeProjectReviewIssue
  ) -> Bool {
    if lhs.severity != rhs.severity {
      return lhs.severity.rawValue > rhs.severity.rawValue
    }
    if lhs.subject != rhs.subject {
      return composeStringOrder(lhs.subject, rhs.subject)
    }
    return composeStringOrder(lhs.message, rhs.message)
  }

  private func isValidLogicalName(_ value: String) -> Bool {
    guard !value.isEmpty else { return false }
    return value.utf8.allSatisfy {
      ($0 >= 48 && $0 <= 57)
        || ($0 >= 65 && $0 <= 90)
        || ($0 >= 97 && $0 <= 122)
        || $0 == 45
        || $0 == 46
        || $0 == 95
    }
  }

  private func isLowercaseSHA256(_ value: String) -> Bool {
    value.count == 64
      && value.utf8.allSatisfy {
        ($0 >= 48 && $0 <= 57) || ($0 >= 97 && $0 <= 102)
      }
  }
}
