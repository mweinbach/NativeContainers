import CryptoKit
import Darwin
import Foundation
import Security

protocol ComposeInputSealing: Sendable {
  func seal(_ data: Data) async throws -> String
}

struct HMACComposeInputSealer: ComposeInputSealing {
  private let key: SymmetricKey

  init(keyData: Data) {
    precondition(keyData.count >= 32)
    key = SymmetricKey(data: keyData)
  }

  func seal(_ data: Data) async throws -> String {
    HMAC<SHA256>.authenticationCode(for: data, using: key)
      .map { String(format: "%02x", $0) }
      .joined()
  }
}

actor KeychainComposeInputSealer: ComposeInputSealing {
  private static let service = "com.nativecontainers.compose-input-sealing"
  private static let account = "hmac-sha256-v1"
  private var cachedKey: SymmetricKey?

  func seal(_ data: Data) async throws -> String {
    let key = try loadOrCreateKey()
    return HMAC<SHA256>.authenticationCode(for: data, using: key)
      .map { String(format: "%02x", $0) }
      .joined()
  }

  private func loadOrCreateKey() throws -> SymmetricKey {
    if let cachedKey { return cachedKey }

    let readQuery: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: Self.service,
      kSecAttrAccount as String: Self.account,
      kSecReturnData as String: true,
      kSecMatchLimit as String: kSecMatchLimitOne,
    ]
    var result: CFTypeRef?
    let readStatus = SecItemCopyMatching(readQuery as CFDictionary, &result)
    if readStatus == errSecSuccess, let data = result as? Data, data.count == 32 {
      let key = SymmetricKey(data: data)
      cachedKey = key
      return key
    }
    guard readStatus == errSecItemNotFound else {
      throw ComposeProjectLifecycleError.unavailable(
        "The Compose input sealing key could not be read from Keychain."
      )
    }

    var bytes = Data(count: 32)
    let randomStatus = bytes.withUnsafeMutableBytes { buffer in
      SecRandomCopyBytes(kSecRandomDefault, buffer.count, buffer.baseAddress!)
    }
    guard randomStatus == errSecSuccess else {
      throw ComposeProjectLifecycleError.unavailable(
        "A Compose input sealing key could not be generated."
      )
    }

    let addQuery: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: Self.service,
      kSecAttrAccount as String: Self.account,
      kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
      kSecValueData as String: bytes,
    ]
    let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
    if addStatus == errSecDuplicateItem {
      var racedResult: CFTypeRef?
      let racedStatus = SecItemCopyMatching(readQuery as CFDictionary, &racedResult)
      guard racedStatus == errSecSuccess,
        let racedData = racedResult as? Data,
        racedData.count == 32
      else {
        throw ComposeProjectLifecycleError.unavailable(
          "The Compose input sealing key could not be recovered from Keychain."
        )
      }
      let key = SymmetricKey(data: racedData)
      cachedKey = key
      return key
    }
    guard addStatus == errSecSuccess else {
      throw ComposeProjectLifecycleError.unavailable(
        "The Compose input sealing key could not be stored in Keychain."
      )
    }

    let key = SymmetricKey(data: bytes)
    cachedKey = key
    return key
  }
}

struct ComposeExecutionInputFile: Equatable, Sendable {
  let id: String
  let data: Data
  let sha256: String
}

struct ComposeProjectInputBinding: Equatable, Sendable {
  let kind: ComposeProjectInputKind
  let name: String
  let sourceKind: ComposeProjectInputSourceKind
  let stagedFileID: String?
}

struct ComposeReviewedInputPayload: Equatable, Sendable {
  let bindings: [ComposeProjectInputBinding]
  let files: [ComposeExecutionInputFile]
  let environmentValues: [String: String]

  static let empty = ComposeReviewedInputPayload(
    bindings: [],
    files: [],
    environmentValues: [:]
  )

  var containsSensitiveValues: Bool {
    !bindings.isEmpty
  }
}

struct ComposePreparedProjectInputs: Sendable {
  let token: UUID?
  let serviceSeals: [String: String]
  let issues: [ComposeProjectReviewIssue]
}

protocol ComposeProjectInputManaging: Sendable {
  func discover(
    source: ComposeProjectSourceLease,
    options: ComposeProjectReviewOptions,
    rendered: ComposeRenderedConfiguration
  ) async throws -> ComposeProjectInputRequirements

  func prepareImmediate(
    source: ComposeProjectSourceLease,
    options: ComposeProjectReviewOptions,
    rendered: ComposeRenderedConfiguration
  ) async throws -> ComposePreparedProjectInputs

  func prepare(
    requirementsID: UUID,
    inputs: ComposeProjectReviewInputs,
    source: ComposeProjectSourceLease,
    options: ComposeProjectReviewOptions,
    rendered: ComposeRenderedConfiguration
  ) async throws -> ComposePreparedProjectInputs

  func bind(token: UUID?, to planID: UUID) async throws
  func payload(for token: UUID?) async throws -> ComposeReviewedInputPayload
  func reviewIssues(for plan: ComposeProjectPlan) async throws -> [ComposeProjectReviewIssue]
  func consume(for plan: ComposeProjectPlan) async throws -> ComposeReviewedInputPayload
  func discard(token: UUID?) async
  func discard(planID: UUID) async
  func discard(requirementsID: UUID) async
}

actor ComposeProjectInputVault: ComposeProjectInputManaging {
  private struct FileIdentity: Equatable, Sendable {
    let device: UInt64
    let inode: UInt64
    let owner: UInt32
    let permissions: UInt16
    let linkCount: UInt64
    let byteCount: Int64
    let modificationSeconds: Int64
    let modificationNanoseconds: Int64
    let changeSeconds: Int64
    let changeNanoseconds: Int64
  }

  private struct Grant: Equatable, Sendable {
    let serviceName: String
    let target: String
    let uid: String?
    let gid: String?
    let mode: Int?
  }

  private struct Resource: Equatable, Sendable {
    let kind: ComposeProjectInputKind
    let name: String
    let sourceKind: ComposeProjectInputSourceKind
    let environmentVariable: String?
    let displayPath: String?
    let sourceURL: URL?
    let fileIdentity: FileIdentity?
    let reviewedData: Data
    let grants: [Grant]
  }

  private struct Discovery: Sendable {
    let source: ComposeProjectSourceSummary
    let directoryURL: URL
    let options: ComposeProjectReviewOptions
    let fullConfigurationSHA256: String
    let resources: [Resource]
    let issues: [ComposeProjectReviewIssue]
  }

  private struct Prepared: Sendable {
    let payload: ComposeReviewedInputPayload
    let serviceSeals: [String: String]
    let issues: [ComposeProjectReviewIssue]
  }

  private static let maximumConfigBytes = 1 * 1_024 * 1_024
  private static let maximumConfigTotalBytes = 4 * 1_024 * 1_024
  private static let maximumConfigCount = 128

  private let sealer: any ComposeInputSealing
  private var discoveries: [UUID: Discovery] = [:]
  private var preparedByToken: [UUID: Prepared] = [:]
  private var preparedByPlan: [UUID: Prepared] = [:]

  init(sealer: any ComposeInputSealing = KeychainComposeInputSealer()) {
    self.sealer = sealer
  }

  func discover(
    source: ComposeProjectSourceLease,
    options: ComposeProjectReviewOptions,
    rendered: ComposeRenderedConfiguration
  ) async throws -> ComposeProjectInputRequirements {
    let parsed = try parseResources(source: source, rendered: rendered)
    let id = UUID()
    let discovery = Discovery(
      source: source.summary,
      directoryURL: source.directoryURL.standardizedFileURL,
      options: options,
      fullConfigurationSHA256: rendered.fullConfigurationSHA256,
      resources: parsed.resources,
      issues: parsed.issues
    )
    discoveries[id] = discovery
    trimDiscoveries()
    return requirements(id: id, discovery: discovery)
  }

  func prepareImmediate(
    source: ComposeProjectSourceLease,
    options: ComposeProjectReviewOptions,
    rendered: ComposeRenderedConfiguration
  ) async throws -> ComposePreparedProjectInputs {
    let requirements = try await discover(
      source: source,
      options: options,
      rendered: rendered
    )
    return try await prepare(
      requirementsID: requirements.id,
      inputs: ComposeProjectReviewInputs(requirementsID: requirements.id),
      source: source,
      options: options,
      rendered: rendered
    )
  }

  func prepare(
    requirementsID: UUID,
    inputs: ComposeProjectReviewInputs,
    source: ComposeProjectSourceLease,
    options: ComposeProjectReviewOptions,
    rendered: ComposeRenderedConfiguration
  ) async throws -> ComposePreparedProjectInputs {
    guard inputs.requirementsID == requirementsID,
      let discovery = discoveries.removeValue(forKey: requirementsID)
    else {
      throw ComposeProjectLifecycleError.inputRequirementsUnavailable
    }
    guard discovery.source == source.summary,
      discovery.directoryURL == source.directoryURL.standardizedFileURL,
      discovery.options == options,
      discovery.fullConfigurationSHA256 == rendered.fullConfigurationSHA256
    else {
      throw ComposeProjectLifecycleError.inputRequirementsMismatch
    }

    let current = try parseResources(source: source, rendered: rendered)
    guard current.resources == discovery.resources, current.issues == discovery.issues else {
      throw ComposeProjectLifecycleError.inputRequirementsMismatch
    }

    let requiredVariables = Set(current.resources.compactMap(\.environmentVariable))
    for name in requiredVariables where inputs.environmentValues[name] == nil {
      throw ComposeProjectLifecycleError.missingInputValue(name)
    }
    for name in inputs.environmentValues.keys where !requiredVariables.contains(name) {
      throw ComposeProjectLifecycleError.unexpectedInputValue(name)
    }

    let prepared = try await preparePayload(
      resources: current.resources,
      environmentValues: inputs.environmentValues,
      issues: current.issues,
      projectName: options.projectName
    )
    guard !prepared.payload.bindings.isEmpty else {
      return ComposePreparedProjectInputs(
        token: nil,
        serviceSeals: [:],
        issues: current.issues
      )
    }
    let token = UUID()
    preparedByToken[token] = prepared
    return ComposePreparedProjectInputs(
      token: token,
      serviceSeals: prepared.serviceSeals,
      issues: current.issues
    )
  }

  func bind(token: UUID?, to planID: UUID) async throws {
    guard let token else { return }
    guard preparedByPlan[planID] == nil,
      let prepared = preparedByToken.removeValue(forKey: token)
    else {
      throw ComposeProjectLifecycleError.inputRequirementsUnavailable
    }
    preparedByPlan[planID] = prepared
    while preparedByPlan.count > 16, let staleID = preparedByPlan.keys.first {
      preparedByPlan.removeValue(forKey: staleID)
    }
  }

  func payload(for token: UUID?) async throws -> ComposeReviewedInputPayload {
    guard let token else { return .empty }
    guard let prepared = preparedByToken[token] else {
      throw ComposeProjectLifecycleError.inputRequirementsUnavailable
    }
    return prepared.payload
  }

  func reviewIssues(for plan: ComposeProjectPlan) async throws -> [ComposeProjectReviewIssue] {
    let expected = serviceSeals(in: plan)
    guard !expected.isEmpty else { return [] }
    guard let prepared = preparedByPlan[plan.id], prepared.serviceSeals == expected else {
      throw ComposeProjectLifecycleError.inputRequirementsUnavailable
    }
    return prepared.issues
  }

  func consume(for plan: ComposeProjectPlan) async throws -> ComposeReviewedInputPayload {
    let expected = serviceSeals(in: plan)
    guard !expected.isEmpty else { return .empty }
    guard let prepared = preparedByPlan.removeValue(forKey: plan.id),
      prepared.serviceSeals == expected
    else {
      throw ComposeProjectLifecycleError.inputRequirementsUnavailable
    }
    return prepared.payload
  }

  func discard(token: UUID?) async {
    guard let token else { return }
    preparedByToken.removeValue(forKey: token)
  }

  func discard(planID: UUID) async {
    preparedByPlan.removeValue(forKey: planID)
  }

  func discard(requirementsID: UUID) async {
    discoveries.removeValue(forKey: requirementsID)
  }

  private func requirements(
    id: UUID,
    discovery: Discovery
  ) -> ComposeProjectInputRequirements {
    ComposeProjectInputRequirements(
      id: id,
      source: discovery.source,
      options: discovery.options,
      inputs: discovery.resources.map { resource in
        ComposeProjectInputRequirement(
          kind: resource.kind,
          name: resource.name,
          sourceKind: resource.sourceKind,
          environmentVariable: resource.environmentVariable,
          displayPath: resource.displayPath,
          byteCount: Int64(resource.reviewedData.count),
          serviceNames: Array(Set(resource.grants.map(\.serviceName))).sorted(
            by: composeStringOrder
          )
        )
      },
      issues: discovery.issues
    )
  }

  private func preparePayload(
    resources: [Resource],
    environmentValues: [String: String],
    issues: [ComposeProjectReviewIssue],
    projectName: String
  ) async throws -> Prepared {
    var bindings: [ComposeProjectInputBinding] = []
    var files: [ComposeExecutionInputFile] = []
    var grantsByService: [String: [(Grant, String)]] = [:]
    var configTotal = 0
    var secretTotal = 0

    for resource in resources {
      let data: Data
      switch resource.sourceKind {
      case .environment:
        guard let variable = resource.environmentVariable,
          let value = environmentValues[variable]
        else {
          throw ComposeProjectLifecycleError.missingInputValue(
            resource.environmentVariable ?? resource.name
          )
        }
        guard !value.utf8.contains(0), let valueData = value.data(using: .utf8) else {
          throw ComposeProjectLifecycleError.configOutputInvalid(
            "A reviewed Compose environment input contains an invalid value."
          )
        }
        data = valueData
      case .file, .literal:
        data = resource.reviewedData
      }
      try validateBoundedData(data, for: resource)
      if resource.kind == .config {
        configTotal += data.count
        guard configTotal <= Self.maximumConfigTotalBytes else {
          throw ComposeProjectLifecycleError.inputSourceTooLarge("configs")
        }
      } else {
        secretTotal += data.count
        guard secretTotal <= ContainerBuildSecretLimits.maximumTotalBytes else {
          throw ComposeProjectLifecycleError.inputSourceTooLarge("secrets")
        }
      }

      var sealedData = Data()
      append(projectName, to: &sealedData)
      append(resource.kind.rawValue, to: &sealedData)
      append(resource.name, to: &sealedData)
      append(resource.sourceKind.rawValue, to: &sealedData)
      sealedData.append(data)
      let resourceSeal = try await sealer.seal(sealedData)
      let stagedFileID: String?
      if resource.sourceKind == .file {
        stagedFileID = resourceSeal
        files.append(
          ComposeExecutionInputFile(
            id: resourceSeal,
            data: data,
            sha256: SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
          )
        )
      } else {
        stagedFileID = nil
      }
      bindings.append(
        ComposeProjectInputBinding(
          kind: resource.kind,
          name: resource.name,
          sourceKind: resource.sourceKind,
          stagedFileID: stagedFileID
        )
      )
      for grant in resource.grants {
        grantsByService[grant.serviceName, default: []].append((grant, resourceSeal))
      }
    }

    var serviceSeals: [String: String] = [:]
    for serviceName in grantsByService.keys.sorted(by: composeStringOrder) {
      var data = Data()
      append(projectName, to: &data)
      append(serviceName, to: &data)
      for (grant, resourceSeal) in grantsByService[serviceName, default: []].sorted(
        by: grantSealOrder
      ) {
        append(resourceSeal, to: &data)
        append(grant.target, to: &data)
        append(grant.uid ?? "", to: &data)
        append(grant.gid ?? "", to: &data)
        append(grant.mode.map(String.init) ?? "", to: &data)
      }
      serviceSeals[serviceName] = try await sealer.seal(data)
    }

    return Prepared(
      payload: ComposeReviewedInputPayload(
        bindings: bindings.sorted(by: bindingOrder),
        files: files.sorted { composeStringOrder($0.id, $1.id) },
        environmentValues: environmentValues
      ),
      serviceSeals: serviceSeals,
      issues: issues
    )
  }

  private func parseResources(
    source: ComposeProjectSourceLease,
    rendered: ComposeRenderedConfiguration
  ) throws -> (resources: [Resource], issues: [ComposeProjectReviewIssue]) {
    let project = try decodeObject(rendered.fullConfiguration)
    let activeProject = try decodeObject(rendered.activeConfiguration)
    guard let services = activeProject["services"] as? [String: Any] else {
      throw ComposeProjectLifecycleError.configOutputInvalid(
        "The canonical input model did not contain services."
      )
    }

    var grants: [String: [Grant]] = [:]
    var issues: [ComposeProjectReviewIssue] = []
    for serviceName in services.keys.sorted(by: composeStringOrder) {
      guard let service = services[serviceName] as? [String: Any] else { continue }
      for kind in [ComposeProjectInputKind.config, .secret] {
        let key = kind == .config ? "configs" : "secrets"
        guard let rawGrants = service[key] else { continue }
        guard let entries = rawGrants as? [Any] else {
          throw ComposeProjectLifecycleError.configOutputInvalid(
            "Service \(serviceName) has an invalid \(key) grant list."
          )
        }
        for entry in entries {
          guard let object = entry as? [String: Any],
            let resourceName = object["source"] as? String,
            !resourceName.isEmpty
          else {
            throw ComposeProjectLifecycleError.configOutputInvalid(
              "Service \(serviceName) has an invalid \(key) grant."
            )
          }
          let grant = Grant(
            serviceName: serviceName,
            target: object["target"] as? String ?? "",
            uid: stringValue(object["uid"]),
            gid: stringValue(object["gid"]),
            mode: integerValue(object["mode"])
          )
          grants[resourceKey(kind: kind, name: resourceName), default: []].append(grant)
        }
      }
    }

    var resources: [Resource] = []
    var configTotal = 0
    var secretTotal = 0
    for kind in [ComposeProjectInputKind.config, .secret] {
      let key = kind == .config ? "configs" : "secrets"
      guard let rawResources = project[key] else { continue }
      guard let objects = rawResources as? [String: Any] else {
        throw ComposeProjectLifecycleError.configOutputInvalid(
          "The canonical \(key) model is invalid."
        )
      }
      if kind == .secret, objects.count > ContainerBuildSecretLimits.maximumCount {
        throw ComposeProjectLifecycleError.inputSourceTooLarge(key)
      }
      if kind == .config, objects.count > Self.maximumConfigCount {
        throw ComposeProjectLifecycleError.inputSourceTooLarge(key)
      }
      for name in objects.keys.sorted(by: composeStringOrder) {
        let key = resourceKey(kind: kind, name: name)
        guard grants[key] != nil else { continue }
        guard let object = objects[name] as? [String: Any] else {
          throw ComposeProjectLifecycleError.configOutputInvalid(
            "Compose input \(name) is not an object."
          )
        }
        let parsed = try parseResource(
          kind: kind,
          name: name,
          object: object,
          grants: grants[key, default: []],
          sourceDirectory: source.directoryURL
        )
        if kind == .config {
          configTotal += parsed.reviewedData.count
          guard configTotal <= Self.maximumConfigTotalBytes else {
            throw ComposeProjectLifecycleError.inputSourceTooLarge("configs")
          }
        } else {
          secretTotal += parsed.reviewedData.count
          guard secretTotal <= ContainerBuildSecretLimits.maximumTotalBytes else {
            throw ComposeProjectLifecycleError.inputSourceTooLarge("secrets")
          }
        }
        for grant in parsed.grants
        where parsed.sourceKind == .file
          && (grant.uid != nil || grant.gid != nil || grant.mode != nil)
        {
          issues.append(
            ComposeProjectReviewIssue(
              severity: .warning,
              code: .inputPolicy,
              subject: grant.serviceName,
              message:
                "File-backed \(kind.rawValue) \(name) ignores uid, gid, and mode in local Compose execution."
            )
          )
        }
        resources.append(parsed)
      }
    }

    let defined = Set(resources.map { resourceKey(kind: $0.kind, name: $0.name) })
    for granted in grants.keys where !defined.contains(granted) {
      throw ComposeProjectLifecycleError.configOutputInvalid(
        "A service grants an undefined Compose config or secret."
      )
    }
    let reviewedEnvironmentVariables = Set(resources.compactMap(\.environmentVariable))
    if let variable = forbiddenEnvironmentReference(
      in: project,
      reviewedVariables: reviewedEnvironmentVariables
    ) {
      throw ComposeProjectLifecycleError.configOutputInvalid(
        "Compose environment input \(variable) is referenced outside its config or secret source declaration."
      )
    }
    return (
      resources.sorted(by: resourceOrder),
      Dictionary(issues.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        .values.sorted { lhs, rhs in lhs.id < rhs.id }
    )
  }

  private func parseResource(
    kind: ComposeProjectInputKind,
    name: String,
    object: [String: Any],
    grants: [Grant],
    sourceDirectory: URL
  ) throws -> Resource {
    guard isSafeInputName(name) else {
      throw ComposeProjectLifecycleError.configOutputInvalid(
        "A Compose config or secret name is invalid."
      )
    }
    let file = object["file"] as? String
    let environment = object["environment"] as? String
    let content = object["content"] as? String
    let sourceCount = [file, environment, content].compactMap { $0 }.count
    guard sourceCount == 1,
      object["external"] as? Bool != true,
      object["driver"] == nil,
      object["template_driver"] == nil
    else {
      throw ComposeProjectLifecycleError.configOutputInvalid(
        "Compose input \(name) must have exactly one local source."
      )
    }
    if kind == .secret, content != nil {
      throw ComposeProjectLifecycleError.configOutputInvalid(
        "Compose secret \(name) cannot use literal content."
      )
    }

    if let file {
      let reviewed = try readSafeFile(
        path: file,
        projectDirectory: sourceDirectory,
        name: name,
        maximumBytes: kind == .config
          ? Self.maximumConfigBytes : ContainerBuildSecretLimits.maximumSecretBytes
      )
      return Resource(
        kind: kind,
        name: name,
        sourceKind: .file,
        environmentVariable: nil,
        displayPath: reviewed.displayPath,
        sourceURL: reviewed.url,
        fileIdentity: reviewed.identity,
        reviewedData: reviewed.data,
        grants: grants.sorted(by: grantOrder)
      )
    }
    if let environment {
      guard isSafeEnvironmentVariable(environment) else {
        throw ComposeProjectLifecycleError.configOutputInvalid(
          "Compose input \(name) uses an unsafe environment variable name."
        )
      }
      return Resource(
        kind: kind,
        name: name,
        sourceKind: .environment,
        environmentVariable: environment,
        displayPath: nil,
        sourceURL: nil,
        fileIdentity: nil,
        reviewedData: Data(),
        grants: grants.sorted(by: grantOrder)
      )
    }
    guard let content, let data = content.data(using: .utf8) else {
      throw ComposeProjectLifecycleError.configOutputInvalid(
        "Compose config \(name) contains invalid literal content."
      )
    }
    guard data.count <= Self.maximumConfigBytes else {
      throw ComposeProjectLifecycleError.inputSourceTooLarge(name)
    }
    return Resource(
      kind: kind,
      name: name,
      sourceKind: .literal,
      environmentVariable: nil,
      displayPath: nil,
      sourceURL: nil,
      fileIdentity: nil,
      reviewedData: data,
      grants: grants.sorted(by: grantOrder)
    )
  }

  private func readSafeFile(
    path: String,
    projectDirectory: URL,
    name: String,
    maximumBytes: Int
  ) throws -> (url: URL, displayPath: String, identity: FileIdentity, data: Data) {
    let root = projectDirectory.standardizedFileURL
    let candidate = URL(filePath: path).standardizedFileURL
    let rootPath = root.nativeContainersPOSIXPath
    let candidatePath = candidate.nativeContainersPOSIXPath
    guard candidate.isFileURL,
      candidatePath.hasPrefix(rootPath + "/"),
      candidatePath.utf8.count > rootPath.utf8.count + 1
    else {
      throw ComposeProjectLifecycleError.inputSourceUnsafe(name)
    }
    let relative = String(candidatePath.dropFirst(rootPath.count + 1))
    let components = relative.split(separator: "/", omittingEmptySubsequences: false).map(
      String.init)
    guard !components.isEmpty,
      components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." })
    else {
      throw ComposeProjectLifecycleError.inputSourceUnsafe(name)
    }

    var descriptor = Darwin.open(
      rootPath,
      O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
    )
    guard descriptor >= 0 else {
      throw ComposeProjectLifecycleError.inputSourceUnsafe(name)
    }
    defer { Darwin.close(descriptor) }
    try validateDirectoryDescriptor(descriptor, name: name)

    for component in components.dropLast() {
      let next = Darwin.openat(
        descriptor,
        component,
        O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
      )
      guard next >= 0 else {
        throw ComposeProjectLifecycleError.inputSourceUnsafe(name)
      }
      Darwin.close(descriptor)
      descriptor = next
      try validateDirectoryDescriptor(descriptor, name: name)
    }

    let fileDescriptor = Darwin.openat(
      descriptor,
      components.last!,
      O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC
    )
    guard fileDescriptor >= 0 else {
      throw ComposeProjectLifecycleError.inputSourceUnsafe(name)
    }
    defer { Darwin.close(fileDescriptor) }

    let before = try fileIdentity(descriptor: fileDescriptor, name: name)
    guard before.byteCount >= 0, before.byteCount <= Int64(maximumBytes) else {
      throw ComposeProjectLifecycleError.inputSourceTooLarge(name)
    }
    let data = try readAll(
      descriptor: fileDescriptor,
      byteCount: Int(before.byteCount),
      name: name
    )
    let after = try fileIdentity(descriptor: fileDescriptor, name: name)
    guard before == after else {
      throw ComposeProjectLifecycleError.inputRequirementsMismatch
    }
    return (candidate, relative, before, data)
  }

  private func validateDirectoryDescriptor(_ descriptor: Int32, name: String) throws {
    var metadata = stat()
    guard Darwin.fstat(descriptor, &metadata) == 0,
      metadata.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR),
      metadata.st_uid == Darwin.geteuid(),
      metadata.st_mode & mode_t(S_IWGRP | S_IWOTH) == 0
    else {
      throw ComposeProjectLifecycleError.inputSourceUnsafe(name)
    }
  }

  private func fileIdentity(descriptor: Int32, name: String) throws -> FileIdentity {
    var metadata = stat()
    guard Darwin.fstat(descriptor, &metadata) == 0,
      metadata.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG),
      metadata.st_uid == Darwin.geteuid(),
      metadata.st_nlink == 1,
      metadata.st_mode & mode_t(S_IWGRP | S_IWOTH) == 0
    else {
      throw ComposeProjectLifecycleError.inputSourceUnsafe(name)
    }
    return FileIdentity(
      device: UInt64(metadata.st_dev),
      inode: UInt64(metadata.st_ino),
      owner: UInt32(metadata.st_uid),
      permissions: UInt16(metadata.st_mode & 0o7777),
      linkCount: UInt64(metadata.st_nlink),
      byteCount: Int64(metadata.st_size),
      modificationSeconds: Int64(metadata.st_mtimespec.tv_sec),
      modificationNanoseconds: Int64(metadata.st_mtimespec.tv_nsec),
      changeSeconds: Int64(metadata.st_ctimespec.tv_sec),
      changeNanoseconds: Int64(metadata.st_ctimespec.tv_nsec)
    )
  }

  private func readAll(descriptor: Int32, byteCount: Int, name: String) throws -> Data {
    guard Darwin.lseek(descriptor, 0, SEEK_SET) == 0 else {
      throw ComposeProjectLifecycleError.inputSourceUnsafe(name)
    }
    var data = Data(count: byteCount)
    try data.withUnsafeMutableBytes { bytes in
      var offset = 0
      while offset < bytes.count {
        let count = Darwin.read(
          descriptor,
          bytes.baseAddress!.advanced(by: offset),
          bytes.count - offset
        )
        if count < 0, errno == EINTR { continue }
        guard count > 0 else {
          throw ComposeProjectLifecycleError.inputSourceUnsafe(name)
        }
        offset += count
      }
    }
    return data
  }

  private func validateBoundedData(_ data: Data, for resource: Resource) throws {
    let maximum =
      resource.kind == .config
      ? Self.maximumConfigBytes : ContainerBuildSecretLimits.maximumSecretBytes
    guard data.count <= maximum else {
      throw ComposeProjectLifecycleError.inputSourceTooLarge(resource.name)
    }
  }

  private func decodeObject(_ data: Data) throws -> [String: Any] {
    do {
      guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
        throw ComposeProjectLifecycleError.configOutputInvalid(
          "The canonical input model was not an object."
        )
      }
      return object
    } catch let error as ComposeProjectLifecycleError {
      throw error
    } catch {
      throw ComposeProjectLifecycleError.configOutputInvalid(
        "The canonical input model was not valid JSON."
      )
    }
  }

  private func isSafeEnvironmentVariable(_ value: String) -> Bool {
    guard value.utf8.count <= 256, let first = value.utf8.first,
      first == 95 || (first >= 65 && first <= 90) || (first >= 97 && first <= 122)
    else { return false }
    guard
      value.utf8.allSatisfy({ byte in
        byte == 95 || (byte >= 48 && byte <= 57) || (byte >= 65 && byte <= 90)
          || (byte >= 97 && byte <= 122)
      })
    else { return false }
    let reserved = [
      "ALL_PROXY", "GODEBUG", "GOTRACEBACK", "HOME", "HTTP_PROXY", "HTTPS_PROXY", "LANG",
      "LOGNAME", "NO_COLOR", "NO_PROXY", "PATH", "SHELL", "TERM", "TMPDIR", "USER",
    ]
    let normalized = value.uppercased()
    return !reserved.contains(normalized)
      && !normalized.hasPrefix("BUILDKIT_")
      && !normalized.hasPrefix("COMPOSE_")
      && !normalized.hasPrefix("DOCKER_")
      && !normalized.hasPrefix("DYLD_")
      && !normalized.hasPrefix("LC_")
      && !normalized.hasPrefix("LD_")
      && !normalized.hasPrefix("XDG_")
  }

  private func isSafeInputName(_ value: String) -> Bool {
    !value.isEmpty && value.utf8.count <= 128
      && value.utf8.allSatisfy {
        ($0 >= 48 && $0 <= 57)
          || ($0 >= 65 && $0 <= 90)
          || ($0 >= 97 && $0 <= 122)
          || $0 == 45
          || $0 == 46
          || $0 == 95
      }
  }

  private func forbiddenEnvironmentReference(
    in value: Any,
    path: [String] = [],
    reviewedVariables: Set<String>
  ) -> String? {
    guard !reviewedVariables.isEmpty else { return nil }
    if let string = value as? String {
      return interpolatedReviewedVariable(in: string, reviewedVariables: reviewedVariables)
    }
    if let array = value as? [Any] {
      if isServiceEnvironmentPath(path),
        let variable = array.compactMap({ $0 as? String }).first(where: {
          reviewedVariables.contains($0)
        })
      {
        return variable
      }
      for (index, element) in array.enumerated() {
        if let variable = forbiddenEnvironmentReference(
          in: element,
          path: path + [String(index)],
          reviewedVariables: reviewedVariables
        ) {
          return variable
        }
      }
      return nil
    }
    guard let object = value as? [String: Any] else { return nil }
    if isServiceEnvironmentPath(path) {
      for variable in reviewedVariables.sorted(by: composeStringOrder)
      where object[variable] is NSNull {
        return variable
      }
    }
    for key in object.keys.sorted(by: composeStringOrder) {
      if let variable = interpolatedReviewedVariable(
        in: key,
        reviewedVariables: reviewedVariables
      ) {
        return variable
      }
      guard let child = object[key] else { continue }
      if let variable = forbiddenEnvironmentReference(
        in: child,
        path: path + [key],
        reviewedVariables: reviewedVariables
      ) {
        return variable
      }
    }
    return nil
  }

  private func isServiceEnvironmentPath(_ path: [String]) -> Bool {
    path.count == 3 && path[0] == "services" && path[2] == "environment"
  }

  private func interpolatedReviewedVariable(
    in value: String,
    reviewedVariables: Set<String>
  ) -> String? {
    let bytes = Array(value.utf8)
    var index = 0
    while index < bytes.count {
      guard bytes[index] == 36 else {
        index += 1
        continue
      }
      var endOfDollarRun = index
      while endOfDollarRun < bytes.count, bytes[endOfDollarRun] == 36 {
        endOfDollarRun += 1
      }
      let dollarCount = endOfDollarRun - index
      guard dollarCount % 2 == 1, endOfDollarRun < bytes.count else {
        index = endOfDollarRun
        continue
      }
      var variableStart = endOfDollarRun
      if bytes[variableStart] == 123 {
        variableStart += 1
      }
      guard variableStart < bytes.count, isEnvironmentVariableStart(bytes[variableStart]) else {
        index = endOfDollarRun
        continue
      }
      var variableEnd = variableStart + 1
      while variableEnd < bytes.count, isEnvironmentVariableContinuation(bytes[variableEnd]) {
        variableEnd += 1
      }
      let variable = String(decoding: bytes[variableStart..<variableEnd], as: UTF8.self)
      if reviewedVariables.contains(variable) { return variable }
      index = variableEnd
    }
    return nil
  }

  private func isEnvironmentVariableStart(_ byte: UInt8) -> Bool {
    byte == 95 || (byte >= 65 && byte <= 90) || (byte >= 97 && byte <= 122)
  }

  private func isEnvironmentVariableContinuation(_ byte: UInt8) -> Bool {
    isEnvironmentVariableStart(byte) || (byte >= 48 && byte <= 57)
  }

  private func serviceSeals(in plan: ComposeProjectPlan) -> [String: String] {
    Dictionary(
      uniqueKeysWithValues: plan.desiredState.activeServices.compactMap { service in
        service.inputSeal.map { (service.name, $0) }
      }
    )
  }

  private func trimDiscoveries() {
    while discoveries.count > 16, let id = discoveries.keys.first {
      discoveries.removeValue(forKey: id)
    }
  }

  private func append(_ value: String, to data: inout Data) {
    data.append(contentsOf: value.utf8)
    data.append(0)
  }

  private func resourceKey(kind: ComposeProjectInputKind, name: String) -> String {
    "\(kind.rawValue):\(name)"
  }

  private func stringValue(_ value: Any?) -> String? {
    if let value = value as? String { return value }
    if let value = value as? NSNumber { return value.stringValue }
    return nil
  }

  private func integerValue(_ value: Any?) -> Int? {
    if let value = value as? Int { return value }
    if let value = value as? NSNumber { return value.intValue }
    if let value = value as? String { return Int(value) }
    return nil
  }

  private func resourceOrder(_ lhs: Resource, _ rhs: Resource) -> Bool {
    if lhs.kind != rhs.kind { return lhs.kind.rawValue < rhs.kind.rawValue }
    return composeStringOrder(lhs.name, rhs.name)
  }

  private func bindingOrder(
    _ lhs: ComposeProjectInputBinding,
    _ rhs: ComposeProjectInputBinding
  ) -> Bool {
    if lhs.kind != rhs.kind { return lhs.kind.rawValue < rhs.kind.rawValue }
    return composeStringOrder(lhs.name, rhs.name)
  }

  private func grantOrder(_ lhs: Grant, _ rhs: Grant) -> Bool {
    if lhs.serviceName != rhs.serviceName {
      return composeStringOrder(lhs.serviceName, rhs.serviceName)
    }
    return composeStringOrder(lhs.target, rhs.target)
  }

  private func grantSealOrder(
    _ lhs: (Grant, String),
    _ rhs: (Grant, String)
  ) -> Bool {
    if lhs.1 != rhs.1 { return composeStringOrder(lhs.1, rhs.1) }
    return grantOrder(lhs.0, rhs.0)
  }
}
