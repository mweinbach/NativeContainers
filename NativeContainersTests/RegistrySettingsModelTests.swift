import Foundation
import Testing

@testable import NativeContainers

@MainActor
struct RegistrySettingsModelTests {
  @Test
  func appleServiceResolvesDockerHubAndRequiresHTTPConfirmationBeforeSaving() async throws {
    let events = RegistryEventRecorder()
    let store = TestRegistryCredentialStore(events: events, expectedPassword: "secret")
    let pinger = TestRegistryEndpointPinger(events: events, expectedPassword: "secret")
    let service = AppleRegistryService(
      credentialStore: store,
      transportResolver: FixedRegistryTransportResolver(transport: .http),
      endpointPinger: pinger
    )

    let plan = try await service.prepareRegistryLogin(
      server: " Docker.IO ",
      username: " octocat ",
      transport: .automatic
    )

    #expect(plan.hostname == "registry-1.docker.io")
    #expect(plan.username == "octocat")
    #expect(plan.requiresInsecureConfirmation)
    await #expect(
      throws: RegistryManagementError.insecureTransportRequiresConfirmation(
        "registry-1.docker.io"
      )
    ) {
      try await service.loginRegistry(
        plan,
        password: "secret",
        allowingInsecureTransport: false,
        replacingDifferentUsername: false
      )
    }
    #expect(await events.values.isEmpty)

    try await service.loginRegistry(
      plan,
      password: "secret",
      allowingInsecureTransport: true,
      replacingDifferentUsername: false
    )

    #expect(await events.values == [.ping, .save])
    #expect(try await service.listRegistries().map(\.hostname) == ["registry-1.docker.io"])
  }

  @Test
  func automaticTransportClassifiesPortlessLocalHostAndRejectsInvalidPorts() async throws {
    let events = RegistryEventRecorder()
    let service = AppleRegistryService(
      credentialStore: TestRegistryCredentialStore(events: events, expectedPassword: "secret"),
      transportResolver: AppleRegistryTransportResolver(
        internalDNSDomainProvider: { "test" }
      ),
      endpointPinger: TestRegistryEndpointPinger(events: events, expectedPassword: "secret")
    )

    let plan = try await service.prepareRegistryLogin(
      server: "LOCALHOST:5000",
      username: "developer",
      transport: .automatic
    )
    #expect(plan.hostname == "localhost:5000")
    #expect(plan.resolvedTransport == .http)

    await #expect(throws: RegistryManagementError.invalidServer("localhost:70000")) {
      _ = try await service.prepareRegistryLogin(
        server: "localhost:70000",
        username: "developer",
        transport: .automatic
      )
    }
    await #expect(
      throws: RegistryManagementError.invalidServer("localhost:999999999999999999999999")
    ) {
      _ = try await service.prepareRegistryLogin(
        server: "localhost:999999999999999999999999",
        username: "developer",
        transport: .automatic
      )
    }
  }

  @Test
  func replacingDifferentRegistryUserRequiresReviewedConfirmation() async throws {
    let events = RegistryEventRecorder()
    let existing = RegistryCredentialRecord(
      hostname: "ghcr.io",
      username: "alice",
      createdAt: Date(timeIntervalSince1970: 1),
      modifiedAt: Date(timeIntervalSince1970: 1)
    )
    let store = TestRegistryCredentialStore(
      events: events,
      expectedPassword: "secret",
      initialRecords: [existing]
    )
    let service = AppleRegistryService(
      credentialStore: store,
      transportResolver: FixedRegistryTransportResolver(transport: .https),
      endpointPinger: TestRegistryEndpointPinger(events: events, expectedPassword: "secret")
    )
    let plan = try await service.prepareRegistryLogin(
      server: "ghcr.io",
      username: "bob",
      transport: .https
    )
    #expect(plan.replacesDifferentUsername)

    await #expect(
      throws: RegistryManagementError.credentialReplacementRequiresConfirmation(
        hostname: "ghcr.io",
        username: "alice"
      )
    ) {
      try await service.loginRegistry(
        plan,
        password: "secret",
        allowingInsecureTransport: false,
        replacingDifferentUsername: false
      )
    }
    #expect(await events.values.isEmpty)

    try await service.loginRegistry(
      plan,
      password: "secret",
      allowingInsecureTransport: false,
      replacingDifferentUsername: true
    )
    #expect(await events.values == [.ping, .save])
    #expect(try await service.listRegistries().map(\.username) == ["bob"])
  }

  @Test
  func credentialChangeDuringPingMakesReviewedLoginStale() async throws {
    let events = RegistryEventRecorder()
    let existing = RegistryCredentialRecord(
      hostname: "ghcr.io",
      username: "alice",
      createdAt: Date(timeIntervalSince1970: 1),
      modifiedAt: Date(timeIntervalSince1970: 1)
    )
    let store = TestRegistryCredentialStore(
      events: events,
      expectedPassword: "secret",
      initialRecords: [existing]
    )
    let pinger = SuspendedRegistryEndpointPinger(events: events)
    let service = AppleRegistryService(
      credentialStore: store,
      transportResolver: FixedRegistryTransportResolver(transport: .https),
      endpointPinger: pinger
    )
    let plan = try await service.prepareRegistryLogin(
      server: "ghcr.io",
      username: "alice",
      transport: .https
    )
    let login = Task {
      try await service.loginRegistry(
        plan,
        password: "secret",
        allowingInsecureTransport: false,
        replacingDifferentUsername: false
      )
    }
    await pinger.waitUntilStarted()
    await store.replaceRecords([
      RegistryCredentialRecord(
        hostname: "ghcr.io",
        username: "alice",
        createdAt: existing.createdAt,
        modifiedAt: Date(timeIntervalSince1970: 2)
      )
    ])
    await pinger.resume()

    await #expect(throws: RegistryManagementError.staleLoginPlan) {
      try await login.value
    }
    #expect(await events.values == [.ping])
  }

  @Test
  func cancellationDuringPingPreventsCredentialSave() async throws {
    let events = RegistryEventRecorder()
    let store = TestRegistryCredentialStore(events: events, expectedPassword: "secret")
    let pinger = SuspendedRegistryEndpointPinger(events: events)
    let service = AppleRegistryService(
      credentialStore: store,
      transportResolver: FixedRegistryTransportResolver(transport: .https),
      endpointPinger: pinger
    )
    let plan = try await service.prepareRegistryLogin(
      server: "ghcr.io",
      username: "alice",
      transport: .https
    )
    let login = Task {
      try await service.loginRegistry(
        plan,
        password: "secret",
        allowingInsecureTransport: false,
        replacingDifferentUsername: false
      )
    }
    await pinger.waitUntilStarted()
    login.cancel()
    await pinger.resume()

    await #expect(throws: CancellationError.self) {
      try await login.value
    }
    #expect(await events.values == [.ping])
    #expect(try await service.listRegistries().isEmpty)
  }

  @Test
  func failedCredentialPingNeverWritesKeychainAdapter() async throws {
    let events = RegistryEventRecorder()
    let store = TestRegistryCredentialStore(events: events, expectedPassword: "secret")
    let service = AppleRegistryService(
      credentialStore: store,
      transportResolver: FixedRegistryTransportResolver(transport: .https),
      endpointPinger: FailingRegistryEndpointPinger()
    )
    let plan = try await service.prepareRegistryLogin(
      server: "ghcr.io",
      username: "alice",
      transport: .https
    )

    await #expect(throws: RegistryTestError.pingFailed) {
      try await service.loginRegistry(
        plan,
        password: "secret",
        allowingInsecureTransport: false,
        replacingDifferentUsername: false
      )
    }
    #expect(await events.values.isEmpty)
    #expect(try await service.listRegistries().isEmpty)
  }

  @Test
  func logoutRefusesCredentialChangedAfterReview() async throws {
    let events = RegistryEventRecorder()
    let reviewed = RegistryCredentialRecord(
      hostname: "ghcr.io",
      username: "alice",
      createdAt: Date(timeIntervalSince1970: 1),
      modifiedAt: Date(timeIntervalSince1970: 1)
    )
    let replacement = RegistryCredentialRecord(
      hostname: "ghcr.io",
      username: "bob",
      createdAt: Date(timeIntervalSince1970: 2),
      modifiedAt: Date(timeIntervalSince1970: 2)
    )
    let store = TestRegistryCredentialStore(
      events: events,
      expectedPassword: "secret",
      initialRecords: [reviewed]
    )
    let service = AppleRegistryService(
      credentialStore: store,
      transportResolver: FixedRegistryTransportResolver(transport: .https),
      endpointPinger: FailingRegistryEndpointPinger()
    )
    await store.replaceRecords([replacement])

    await #expect(throws: RegistryManagementError.staleLogoutPlan) {
      try await service.logoutRegistry(reviewed)
    }
    #expect(try await service.listRegistries() == [replacement])
  }

  @Test
  func explicitHTTPSResolutionDoesNotLoadRuntimeConfiguration() async throws {
    let resolver = AppleRegistryTransportResolver(
      internalDNSDomainProvider: { throw RegistryTestError.unexpectedConfigurationLoad }
    )

    let transport = try await resolver.resolve(
      hostname: "ghcr.io",
      requestedTransport: .https
    )

    #expect(transport == .https)
  }

  @Test
  func invalidRegistryInputNeverPingsOrWritesKeychainAdapter() async {
    let events = RegistryEventRecorder()
    let service = AppleRegistryService(
      credentialStore: TestRegistryCredentialStore(events: events, expectedPassword: "secret"),
      transportResolver: FixedRegistryTransportResolver(transport: .https),
      endpointPinger: TestRegistryEndpointPinger(events: events, expectedPassword: "secret")
    )

    await #expect(throws: RegistryManagementError.invalidServer("not a host/path")) {
      _ = try await service.prepareRegistryLogin(
        server: "not a host/path",
        username: "user",
        transport: .https
      )
    }
    #expect(await events.values.isEmpty)
  }

  @Test
  func settingsModelRefreshesMetadataAfterLoginAndLogout() async throws {
    let service = TestRegistryManagingService()
    let model = RegistrySettingsModel(service: service)

    await model.load()
    #expect(model.registries.isEmpty)

    let plan = await model.prepareLogin(
      server: "ghcr.io",
      username: "octocat",
      transport: .https
    )
    #expect(plan?.resolvedTransport == .https)
    #expect(
      await model.login(
        password: "token",
        allowingInsecureTransport: false,
        replacingDifferentUsername: false
      )
    )
    #expect(model.registries.map(\.hostname) == ["ghcr.io"])
    #expect(await service.receivedInsecureAllowance == false)

    let registry = try #require(model.registries.first)
    #expect(await model.logout(registry))
    #expect(model.registries.isEmpty)
    #expect(await service.loggedOutHostnames == ["ghcr.io"])
  }

  @Test
  func settingsModelReportsRefreshWarningAfterSuccessfulMutation() async {
    let service = RefreshFailingRegistryManagingService()
    let model = RegistrySettingsModel(service: service)

    _ = await model.prepareLogin(
      server: "ghcr.io",
      username: "octocat",
      transport: .https
    )
    let succeeded = await model.login(
      password: "token",
      allowingInsecureTransport: false,
      replacingDifferentUsername: false
    )

    #expect(succeeded)
    #expect(model.errorMessage?.contains("was saved") == true)
    #expect(await service.loginCount == 1)
  }
}

private enum RegistryTestEvent: Equatable, Sendable {
  case ping
  case save
}

private actor RegistryEventRecorder {
  private(set) var values: [RegistryTestEvent] = []

  func append(_ value: RegistryTestEvent) {
    values.append(value)
  }
}

private actor TestRegistryCredentialStore: RegistryCredentialStoring {
  private let events: RegistryEventRecorder
  private let expectedPassword: String
  private var records: [RegistryCredentialRecord]

  init(
    events: RegistryEventRecorder,
    expectedPassword: String,
    initialRecords: [RegistryCredentialRecord] = []
  ) {
    self.events = events
    self.expectedPassword = expectedPassword
    records = initialRecords
  }

  func list() async -> [RegistryCredentialRecord] { records }

  func save(hostname: String, username: String, password: String) async throws {
    guard password == expectedPassword else { throw RegistryTestError.unexpectedPassword }
    await events.append(.save)
    records = [
      RegistryCredentialRecord(
        hostname: hostname,
        username: username,
        createdAt: Date(timeIntervalSince1970: 1),
        modifiedAt: Date(timeIntervalSince1970: 1)
      )
    ]
  }

  func delete(hostname: String) async {
    records.removeAll { $0.hostname == hostname }
  }

  func replaceRecords(_ records: [RegistryCredentialRecord]) {
    self.records = records
  }
}

private struct FixedRegistryTransportResolver: RegistryTransportResolving {
  let transport: RegistryTransport

  func resolve(
    hostname: String,
    requestedTransport: RegistryTransport
  ) async -> RegistryTransport {
    transport
  }
}

private struct TestRegistryEndpointPinger: RegistryEndpointPinging {
  let events: RegistryEventRecorder
  let expectedPassword: String

  func ping(
    hostname: String,
    transport: RegistryTransport,
    username: String,
    password: String
  ) async throws {
    guard password == expectedPassword else { throw RegistryTestError.unexpectedPassword }
    await events.append(.ping)
  }
}

private actor SuspendedRegistryEndpointPinger: RegistryEndpointPinging {
  private let events: RegistryEventRecorder
  private var hasStarted = false
  private var startWaiters: [CheckedContinuation<Void, Never>] = []
  private var pingContinuation: CheckedContinuation<Void, Never>?

  init(events: RegistryEventRecorder) {
    self.events = events
  }

  func ping(
    hostname: String,
    transport: RegistryTransport,
    username: String,
    password: String
  ) async {
    await events.append(.ping)
    hasStarted = true
    let waiters = startWaiters
    startWaiters.removeAll()
    for waiter in waiters {
      waiter.resume()
    }
    await withCheckedContinuation { continuation in
      pingContinuation = continuation
    }
  }

  func waitUntilStarted() async {
    guard !hasStarted else { return }
    await withCheckedContinuation { continuation in
      startWaiters.append(continuation)
    }
  }

  func resume() {
    pingContinuation?.resume()
    pingContinuation = nil
  }
}

private struct FailingRegistryEndpointPinger: RegistryEndpointPinging {
  func ping(
    hostname: String,
    transport: RegistryTransport,
    username: String,
    password: String
  ) async throws {
    throw RegistryTestError.pingFailed
  }
}

private actor TestRegistryManagingService: RegistryManaging {
  private var records: [RegistryCredentialRecord] = []
  private(set) var receivedInsecureAllowance: Bool?
  private(set) var loggedOutHostnames: [String] = []

  func listRegistries() async -> [RegistryCredentialRecord] { records }

  func prepareRegistryLogin(
    server: String,
    username: String,
    transport: RegistryTransport
  ) async -> RegistryLoginPlan {
    RegistryLoginPlan(
      requestedServer: server,
      hostname: server,
      username: username,
      requestedTransport: transport,
      resolvedTransport: .https,
      existingCredential: nil
    )
  }

  func loginRegistry(
    _ plan: RegistryLoginPlan,
    password: String,
    allowingInsecureTransport: Bool,
    replacingDifferentUsername: Bool
  ) async throws {
    guard password == "token" else { throw RegistryTestError.unexpectedPassword }
    receivedInsecureAllowance = allowingInsecureTransport
    records = [
      RegistryCredentialRecord(
        hostname: plan.hostname,
        username: plan.username,
        createdAt: Date(timeIntervalSince1970: 1),
        modifiedAt: Date(timeIntervalSince1970: 1)
      )
    ]
  }

  func logoutRegistry(_ registry: RegistryCredentialRecord) async {
    loggedOutHostnames.append(registry.hostname)
    records.removeAll { $0.hostname == registry.hostname }
  }
}

private actor RefreshFailingRegistryManagingService: RegistryManaging {
  private(set) var loginCount = 0

  func listRegistries() async throws -> [RegistryCredentialRecord] {
    throw RegistryTestError.refreshFailed
  }

  func prepareRegistryLogin(
    server: String,
    username: String,
    transport: RegistryTransport
  ) async -> RegistryLoginPlan {
    RegistryLoginPlan(
      requestedServer: server,
      hostname: server,
      username: username,
      requestedTransport: transport,
      resolvedTransport: .https,
      existingCredential: nil
    )
  }

  func loginRegistry(
    _ plan: RegistryLoginPlan,
    password: String,
    allowingInsecureTransport: Bool,
    replacingDifferentUsername: Bool
  ) async {
    loginCount += 1
  }
}

private enum RegistryTestError: Error {
  case unexpectedPassword
  case unexpectedConfigurationLoad
  case refreshFailed
  case pingFailed
}
