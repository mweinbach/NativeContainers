import Foundation

protocol ComposeCanonicalModelValidating: Sendable {
  func reviewIssues(
    fullConfiguration: Data,
    activeConfiguration: Data,
    projectName: String
  ) throws -> [ComposeProjectReviewIssue]
}

struct ComposeCanonicalModelValidator: ComposeCanonicalModelValidating {
  private typealias JSONObject = [String: Any]

  private struct Violation: Hashable {
    let subject: String
    let message: String
  }

  func reviewIssues(
    fullConfiguration: Data,
    activeConfiguration: Data,
    projectName: String
  ) throws -> [ComposeProjectReviewIssue] {
    var violations: Set<Violation> = []
    for configuration in [fullConfiguration, activeConfiguration] {
      let object = try decodeObject(configuration)
      inspect(object, projectName: projectName, violations: &violations)
    }
    return violations.sorted(by: violationOrder).map {
      ComposeProjectReviewIssue(
        severity: .blocker,
        code: .unsupportedFeature,
        subject: $0.subject,
        message: $0.message
      )
    }
  }

  private func inspect(
    _ project: JSONObject,
    projectName: String,
    violations: inout Set<Violation>
  ) {
    reportUnknownKeys(
      in: project,
      allowed: ["configs", "name", "networks", "secrets", "services", "volumes"],
      subject: projectName,
      context: "project",
      violations: &violations
    )

    inspectServices(
      project["services"],
      violations: &violations
    )
    inspectResources(
      project["volumes"],
      kind: "volume",
      allowedKeys: ["driver", "driver_opts", "external", "labels", "name"],
      violations: &violations
    )
    inspectInputResources(project["configs"], kind: "config", violations: &violations)
    inspectInputResources(project["secrets"], kind: "secret", violations: &violations)
    inspectResources(
      project["networks"],
      kind: "network",
      allowedKeys: [
        "driver", "driver_opts", "external", "ipam", "labels", "name",
      ],
      violations: &violations
    )
  }

  private func inspectServices(
    _ value: Any?,
    violations: inout Set<Violation>
  ) {
    guard let services = value as? JSONObject else { return }
    let allowedServiceKeys: Set<String> = [
      "command",
      "configs",
      "container_name",
      "depends_on",
      "deploy",
      "dns",
      "dns_opt",
      "dns_search",
      "domainname",
      "entrypoint",
      "environment",
      "hostname",
      "healthcheck",
      "image",
      "labels",
      "networks",
      "platform",
      "ports",
      "profiles",
      "restart",
      "scale",
      "secrets",
      "stdin_open",
      "tty",
      "user",
      "volumes",
      "working_dir",
    ]

    for serviceName in services.keys.sorted(by: composeStringOrder) {
      guard let service = services[serviceName] as? JSONObject else { continue }
      reportUnknownKeys(
        in: service,
        allowed: allowedServiceKeys,
        subject: serviceName,
        context: "service",
        violations: &violations
      )
      inspectDeploy(
        service["deploy"],
        serviceName: serviceName,
        violations: &violations
      )
      inspectMounts(
        service["volumes"],
        serviceName: serviceName,
        violations: &violations
      )
      inspectNetworkAttachments(
        service["networks"],
        serviceName: serviceName,
        violations: &violations
      )
      inspectPorts(
        service["ports"],
        serviceName: serviceName,
        violations: &violations
      )
      inspectInputGrants(
        service["configs"],
        kind: "config",
        serviceName: serviceName,
        violations: &violations
      )
      inspectInputGrants(
        service["secrets"],
        kind: "secret",
        serviceName: serviceName,
        violations: &violations
      )
      inspectReservedLabels(
        service["labels"],
        serviceName: serviceName,
        violations: &violations
      )
    }
  }

  private func inspectInputGrants(
    _ value: Any?,
    kind: String,
    serviceName: String,
    violations: inout Set<Violation>
  ) {
    guard let grants = value as? [Any] else { return }
    for grant in grants {
      guard let grant = grant as? JSONObject else { continue }
      reportUnknownKeys(
        in: grant,
        allowed: ["gid", "mode", "source", "target", "uid"],
        subject: serviceName,
        context: "\(kind) grant",
        violations: &violations
      )
    }
  }

  private func inspectReservedLabels(
    _ value: Any?,
    serviceName: String,
    violations: inout Set<Violation>
  ) {
    let names: [String]
    if let labels = value as? JSONObject {
      names = Array(labels.keys)
    } else if let labels = value as? [String] {
      names = labels.map { String($0.split(separator: "=", maxSplits: 1)[0]) }
    } else {
      return
    }
    if names.contains(where: { $0.hasPrefix(ComposeLabelKey.nativePrefix) }) {
      violations.insert(
        Violation(
          subject: serviceName,
          message: "The service uses a label reserved for NativeContainers Compose review."
        )
      )
    }
  }

  private func inspectDeploy(
    _ value: Any?,
    serviceName: String,
    violations: inout Set<Violation>
  ) {
    guard let deploy = value as? JSONObject else { return }
    reportUnknownKeys(
      in: deploy,
      allowed: ["placement", "replicas", "resources"],
      subject: serviceName,
      context: "deploy",
      violations: &violations
    )
    for key in ["placement", "resources"]
    where hasMeaningfulValue(deploy[key]) {
      violations.insert(
        Violation(
          subject: serviceName,
          message: "The service uses unsupported deploy.\(key) configuration."
        )
      )
    }
  }

  private func inspectMounts(
    _ value: Any?,
    serviceName: String,
    violations: inout Set<Violation>
  ) {
    guard let mounts = value as? [Any] else { return }
    for mount in mounts {
      guard let mount = mount as? JSONObject else { continue }
      reportUnknownKeys(
        in: mount,
        allowed: ["read_only", "source", "target", "type", "volume"],
        subject: serviceName,
        context: "volume mount",
        violations: &violations
      )
      if let options = mount["volume"] as? JSONObject,
        hasMeaningfulValue(options)
      {
        violations.insert(
          Violation(
            subject: serviceName,
            message: "Named-volume copy and subpath options are not supported."
          )
        )
      }
    }
  }

  private func inspectNetworkAttachments(
    _ value: Any?,
    serviceName: String,
    violations: inout Set<Violation>
  ) {
    guard let networks = value as? JSONObject else { return }
    for networkName in networks.keys.sorted(by: composeStringOrder) {
      let attachment = networks[networkName]
      guard !(attachment is NSNull), let attachment = attachment as? JSONObject else {
        continue
      }
      reportUnknownKeys(
        in: attachment,
        allowed: ["aliases"],
        subject: serviceName,
        context: "network attachment",
        violations: &violations
      )
    }
  }

  private func inspectPorts(
    _ value: Any?,
    serviceName: String,
    violations: inout Set<Violation>
  ) {
    guard let ports = value as? [Any] else { return }
    for port in ports {
      guard let port = port as? JSONObject else { continue }
      reportUnknownKeys(
        in: port,
        allowed: ["host_ip", "mode", "protocol", "published", "target"],
        subject: serviceName,
        context: "published port",
        violations: &violations
      )
      if let mode = port["mode"] as? String,
        mode != "ingress"
      {
        violations.insert(
          Violation(
            subject: serviceName,
            message: "Only ingress-mode published ports are supported."
          )
        )
      }
    }
  }

  private func inspectResources(
    _ value: Any?,
    kind: String,
    allowedKeys: Set<String>,
    violations: inout Set<Violation>
  ) {
    guard let resources = value as? JSONObject else { return }
    for logicalName in resources.keys.sorted(by: composeStringOrder) {
      guard let resource = resources[logicalName] as? JSONObject else { continue }
      reportUnknownKeys(
        in: resource,
        allowed: allowedKeys,
        subject: logicalName,
        context: kind,
        violations: &violations
      )
      if hasMeaningfulValue(resource["labels"]) {
        violations.insert(
          Violation(
            subject: logicalName,
            message:
              "Custom \(kind) labels are not supported by native resource creation."
          )
        )
      }
    }
  }

  private func inspectInputResources(
    _ value: Any?,
    kind: String,
    violations: inout Set<Violation>
  ) {
    guard let resources = value as? JSONObject else { return }
    for name in resources.keys.sorted(by: composeStringOrder) {
      guard let resource = resources[name] as? JSONObject else { continue }
      reportUnknownKeys(
        in: resource,
        allowed: [
          "content", "driver", "environment", "external", "file", "name",
          "template_driver",
        ],
        subject: name,
        context: kind,
        violations: &violations
      )
      if resource["external"] as? Bool == true
        || hasMeaningfulValue(resource["driver"])
        || hasMeaningfulValue(resource["template_driver"])
      {
        violations.insert(
          Violation(
            subject: name,
            message: "External, driver-backed, and templated Compose \(kind)s are not supported."
          )
        )
      }
      if kind == "secret", hasMeaningfulValue(resource["content"]) {
        violations.insert(
          Violation(
            subject: name,
            message: "Literal content is supported for Compose configs, not secrets."
          )
        )
      }
    }
  }

  private func reportUnknownKeys(
    in object: JSONObject,
    allowed: Set<String>,
    subject: String,
    context: String,
    violations: inout Set<Violation>
  ) {
    for key in object.keys.sorted(by: composeStringOrder)
    where !allowed.contains(key) {
      violations.insert(
        Violation(
          subject: subject,
          message: "The canonical \(context) contains unsupported key \(key)."
        )
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

  private func hasMeaningfulValue(_ value: Any?) -> Bool {
    switch value {
    case nil, is NSNull:
      false
    case let value as Bool:
      value
    case let value as String:
      !value.isEmpty
    case let value as [Any]:
      !value.isEmpty
    case let value as JSONObject:
      !value.isEmpty
    default:
      true
    }
  }

  private func violationOrder(_ lhs: Violation, _ rhs: Violation) -> Bool {
    if lhs.subject != rhs.subject {
      return composeStringOrder(lhs.subject, rhs.subject)
    }
    return composeStringOrder(lhs.message, rhs.message)
  }
}
