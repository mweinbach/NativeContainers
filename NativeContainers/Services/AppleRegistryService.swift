import ContainerAPIClient
import ContainerResource
import ContainerizationExtras
import ContainerizationOCI
import Foundation

actor AppleRegistryService: RegistryManaging {
  private let credentialStore: any RegistryCredentialStoring
  private let transportResolver: any RegistryTransportResolving
  private let endpointPinger: any RegistryEndpointPinging
  private let credentialMutationGate = AsyncLock()

  init(
    credentialStore: any RegistryCredentialStoring = AppleRegistryCredentialStore(),
    transportResolver: any RegistryTransportResolving = AppleRegistryTransportResolver(),
    endpointPinger: any RegistryEndpointPinging = AppleRegistryEndpointPinger()
  ) {
    self.credentialStore = credentialStore
    self.transportResolver = transportResolver
    self.endpointPinger = endpointPinger
  }

  func listRegistries() async throws -> [RegistryCredentialRecord] {
    try await credentialStore.list().sorted {
      $0.hostname.localizedStandardCompare($1.hostname) == .orderedAscending
    }
  }

  func prepareRegistryLogin(
    server: String,
    username: String,
    transport: RegistryTransport
  ) async throws -> RegistryLoginPlan {
    let requestedServer = server.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !requestedServer.isEmpty else { throw RegistryManagementError.missingServer }
    let endpoint = try RegistryEndpoint(server: requestedServer)
    let username = username.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !username.isEmpty else { throw RegistryManagementError.missingUsername }
    let resolvedTransport = try await transportResolver.resolve(
      hostname: endpoint.connectionHost,
      requestedTransport: transport
    )
    guard resolvedTransport != .automatic else {
      throw RegistryManagementError.invalidResolvedTransport
    }
    let existingCredential = try await credentialStore.list().first {
      $0.hostname == endpoint.hostname
    }
    return RegistryLoginPlan(
      requestedServer: requestedServer,
      hostname: endpoint.hostname,
      username: username,
      requestedTransport: transport,
      resolvedTransport: resolvedTransport,
      existingCredential: existingCredential
    )
  }

  func loginRegistry(
    _ plan: RegistryLoginPlan,
    password: String,
    allowingInsecureTransport: Bool,
    replacingDifferentUsername: Bool
  ) async throws {
    try await credentialMutationGate.withLock { _ in
      try await self.loginRegistryWhileLocked(
        plan,
        password: password,
        allowingInsecureTransport: allowingInsecureTransport,
        replacingDifferentUsername: replacingDifferentUsername
      )
    }
  }

  private func loginRegistryWhileLocked(
    _ plan: RegistryLoginPlan,
    password: String,
    allowingInsecureTransport: Bool,
    replacingDifferentUsername: Bool
  ) async throws {
    guard RegistryResource.nameValid(plan.hostname) else {
      throw RegistryManagementError.invalidServer(plan.hostname)
    }
    guard !plan.username.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
      throw RegistryManagementError.missingUsername
    }
    guard !password.isEmpty else { throw RegistryManagementError.missingPassword }
    guard plan.resolvedTransport != .automatic else {
      throw RegistryManagementError.invalidResolvedTransport
    }
    if plan.requiresInsecureConfirmation, !allowingInsecureTransport {
      throw RegistryManagementError.insecureTransportRequiresConfirmation(plan.hostname)
    }
    let currentCredential = try await credentialStore.list().first {
      $0.hostname == plan.hostname
    }
    guard currentCredential == plan.existingCredential else {
      throw RegistryManagementError.staleLoginPlan
    }
    if plan.replacesDifferentUsername, !replacingDifferentUsername {
      throw RegistryManagementError.credentialReplacementRequiresConfirmation(
        hostname: plan.hostname,
        username: plan.existingUsername ?? "existing user"
      )
    }

    try await endpointPinger.ping(
      hostname: plan.hostname,
      transport: plan.resolvedTransport,
      username: plan.username,
      password: password
    )
    try Task.checkCancellation()
    let credentialAfterPing = try await credentialStore.list().first {
      $0.hostname == plan.hostname
    }
    guard credentialAfterPing == plan.existingCredential else {
      throw RegistryManagementError.staleLoginPlan
    }
    try Task.checkCancellation()
    try await credentialStore.save(
      hostname: plan.hostname,
      username: plan.username,
      password: password
    )
  }

  func logoutRegistry(_ registry: RegistryCredentialRecord) async throws {
    try await credentialMutationGate.withLock { _ in
      let endpoint = try RegistryEndpoint(server: registry.hostname)
      let current = try await self.credentialStore.list().first {
        $0.hostname == endpoint.hostname
      }
      guard current == registry else { throw RegistryManagementError.staleLogoutPlan }
      try Task.checkCancellation()
      try await self.credentialStore.delete(hostname: endpoint.hostname)
    }
  }
}

private struct RegistryEndpoint {
  let hostname: String
  let connectionHost: String

  init(server: String) throws {
    let requested = server.trimmingCharacters(in: .whitespacesAndNewlines)
    let lowered = requested.lowercased()
    let dockerHelperAlias = lowered.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    let hostname: String
    switch dockerHelperAlias {
    case "docker.io", "index.docker.io", "https://index.docker.io/v1":
      hostname = "registry-1.docker.io"
    default:
      hostname = Reference.resolveDomain(domain: lowered)
    }
    guard RegistryResource.nameValid(hostname),
      let components = URLComponents(string: "https://\(hostname)"),
      let connectionHost = components.host,
      components.path.isEmpty,
      components.query == nil,
      components.fragment == nil
    else {
      throw RegistryManagementError.invalidServer(requested)
    }
    let hasExplicitPort =
      hostname.hasPrefix("[")
      ? hostname.contains("]:")
      : hostname.contains(":")
    if hasExplicitPort {
      guard let port = components.port, (1...65_535).contains(port) else {
        throw RegistryManagementError.invalidServer(requested)
      }
    }
    self.hostname = hostname
    self.connectionHost = connectionHost
  }
}

protocol RegistryCredentialStoring: Sendable {
  func list() async throws -> [RegistryCredentialRecord]
  func save(hostname: String, username: String, password: String) async throws
  func delete(hostname: String) async throws
}

struct AppleRegistryCredentialStore: RegistryCredentialStoring {
  private let keychain = KeychainHelper(securityDomain: Constants.keychainID)

  func list() async throws -> [RegistryCredentialRecord] {
    try keychain.list().map {
      RegistryCredentialRecord(
        hostname: $0.hostname,
        username: $0.username,
        createdAt: $0.createdDate,
        modifiedAt: $0.modifiedDate
      )
    }
  }

  func save(hostname: String, username: String, password: String) async throws {
    try keychain.save(hostname: hostname, username: username, password: password)
  }

  func delete(hostname: String) async throws {
    try keychain.delete(hostname: hostname)
  }
}

protocol RegistryTransportResolving: Sendable {
  func resolve(
    hostname: String,
    requestedTransport: RegistryTransport
  ) async throws -> RegistryTransport
}

struct AppleRegistryTransportResolver: RegistryTransportResolving {
  private let internalDNSDomainProvider: @Sendable () async throws -> String?

  init(
    internalDNSDomainProvider: @escaping @Sendable () async throws -> String? = {
      try await AppleContainerConfiguration.load().dns.domain
    }
  ) {
    self.internalDNSDomainProvider = internalDNSDomainProvider
  }

  func resolve(
    hostname: String,
    requestedTransport: RegistryTransport
  ) async throws -> RegistryTransport {
    guard requestedTransport == .automatic else { return requestedTransport }
    let requestScheme = try RequestScheme(requestedTransport.rawValue)
    let resolved = try requestScheme.schemeFor(
      host: hostname,
      internalDnsDomain: try await internalDNSDomainProvider()
    )
    guard let transport = RegistryTransport(rawValue: resolved.rawValue) else {
      throw RegistryManagementError.invalidResolvedTransport
    }
    return transport
  }
}

protocol RegistryEndpointPinging: Sendable {
  func ping(
    hostname: String,
    transport: RegistryTransport,
    username: String,
    password: String
  ) async throws
}

struct AppleRegistryEndpointPinger: RegistryEndpointPinging {
  func ping(
    hostname: String,
    transport: RegistryTransport,
    username: String,
    password: String
  ) async throws {
    guard transport != .automatic else {
      throw RegistryManagementError.invalidResolvedTransport
    }
    guard let url = URL(string: "\(transport.rawValue)://\(hostname)"),
      let host = url.host
    else {
      throw RegistryManagementError.invalidServer(hostname)
    }
    let client = RegistryClient(
      host: host,
      scheme: transport.rawValue,
      port: url.port,
      authentication: BasicAuthentication(username: username, password: password),
      retryOptions: RetryOptions(
        maxRetries: 10,
        retryInterval: 300_000_000,
        shouldRetry: { response in response.status.code >= 500 }
      )
    )
    try await client.ping()
  }
}
