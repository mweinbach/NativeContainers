import Foundation
import Testing

@testable import NativeContainers

struct ContainerBuilderSafetyPolicyTests {
  @Test
  func mountIdentityNormalizesOnlyTrailingDirectorySeparators() {
    let persisted = ContainerBuilderMountIdentity(
      type: "virtiofs",
      source: "/Users/example/Library/Application Support/runtime/builder",
      destination: "/exports",
      options: []
    )
    let directoryURL = ContainerBuilderMountIdentity(
      type: "virtiofs",
      source: "/Users/example/Library/Application Support/runtime/builder/",
      destination: "/exports",
      options: []
    )
    let differentPath = ContainerBuilderMountIdentity(
      type: "virtiofs",
      source: "/Users/example/Library/Application Support/runtime/other/",
      destination: "/exports",
      options: []
    )

    #expect(directoryURL == persisted)
    #expect(differentPath != persisted)
  }

  @Test
  func failedCreateCleanupNeverStopsAnAmbiguouslyStartedBuilder() {
    #expect(
      ContainerBuilderSafetyPolicy.failedCreateCleanupAction(for: .running) == .leaveIntact
    )
    #expect(
      ContainerBuilderSafetyPolicy.failedCreateCleanupAction(for: .stopping) == .leaveIntact
    )
    #expect(
      ContainerBuilderSafetyPolicy.failedCreateCleanupAction(for: .unknown) == .leaveIntact
    )
    #expect(
      ContainerBuilderSafetyPolicy.failedCreateCleanupAction(for: .stopped) == .deleteStopped
    )
  }

  private let gibibyte: UInt64 = 1_073_741_824

  @Test
  func everyDecisionBranchIsFailClosed() {
    let desired = makeConfiguration()
    let identity = makeIdentity()
    let drifted = makeConfiguration(image: "registry.example/apple/builder:changed")
    let destructive = ContainerBuilderSafetyAuthorization(
      allowsRecreateStoppedBuilder: true,
      allowsStopRunningBuilder: true
    )
    let cases: [DecisionCase] = [
      DecisionCase(
        name: "absent",
        snapshot: .absent,
        authorization: .none,
        action: .create,
        reason: .absentCreate,
        error: nil
      ),
      DecisionCase(
        name: "exact running",
        snapshot: makeSnapshot(state: .running, identity: identity, configuration: desired),
        authorization: .none,
        action: .reuse,
        reason: .exactRunningReuse,
        error: nil
      ),
      DecisionCase(
        name: "exact stopped",
        snapshot: makeSnapshot(state: .stopped, identity: identity, configuration: desired),
        authorization: .none,
        action: .start,
        reason: .exactStoppedStart,
        error: nil
      ),
      DecisionCase(
        name: "stopping",
        snapshot: makeSnapshot(state: .stopping, identity: identity, configuration: desired),
        authorization: destructive,
        action: nil,
        reason: .stoppingDenied,
        error: .stopping
      ),
      DecisionCase(
        name: "unknown",
        snapshot: makeSnapshot(state: .unknown, identity: identity, configuration: desired),
        authorization: destructive,
        action: nil,
        reason: .unknownDenied,
        error: .unknownState
      ),
      DecisionCase(
        name: "running drift denied",
        snapshot: makeSnapshot(state: .running, identity: identity, configuration: drifted),
        authorization: .none,
        action: nil,
        reason: .runningDriftDenied,
        error: .runningDrift
      ),
      DecisionCase(
        name: "stopped permission does not authorize running drift",
        snapshot: makeSnapshot(state: .running, identity: identity, configuration: drifted),
        authorization: ContainerBuilderSafetyAuthorization(
          allowsRecreateStoppedBuilder: true,
          allowsStopRunningBuilder: false
        ),
        action: nil,
        reason: .runningDriftDenied,
        error: .runningDrift
      ),
      DecisionCase(
        name: "running drift authorized",
        snapshot: makeSnapshot(state: .running, identity: identity, configuration: drifted),
        authorization: destructive,
        action: .stopDeleteCreate,
        reason: .runningDriftRecreate,
        error: nil
      ),
      DecisionCase(
        name: "stopped drift denied",
        snapshot: makeSnapshot(state: .stopped, identity: identity, configuration: drifted),
        authorization: .none,
        action: nil,
        reason: .stoppedDriftDenied,
        error: .stoppedDrift
      ),
      DecisionCase(
        name: "running permission does not authorize stopped drift",
        snapshot: makeSnapshot(state: .stopped, identity: identity, configuration: drifted),
        authorization: ContainerBuilderSafetyAuthorization(
          allowsRecreateStoppedBuilder: false,
          allowsStopRunningBuilder: true
        ),
        action: nil,
        reason: .stoppedDriftDenied,
        error: .stoppedDrift
      ),
      DecisionCase(
        name: "stopped drift authorized",
        snapshot: makeSnapshot(state: .stopped, identity: identity, configuration: drifted),
        authorization: destructive,
        action: .deleteCreate,
        reason: .stoppedDriftRecreate,
        error: nil
      ),
    ]

    for testCase in cases {
      let decision = evaluate(
        snapshot: testCase.snapshot,
        desired: desired,
        authorization: testCase.authorization
      )
      #expect(decision.action == testCase.action, Comment(rawValue: testCase.name))
      #expect(decision.reasonCode == testCase.reason, Comment(rawValue: testCase.name))
      #expect(decision.errorCode == testCase.error, Comment(rawValue: testCase.name))
      #expect(decision.isAllowed == (testCase.action != nil), Comment(rawValue: testCase.name))
    }
  }

  @Test
  func everyPinnedIdentityFieldMustMatch() {
    let exact = makeIdentity()
    let cases: [(String, ContainerBuilderIdentitySnapshot?, ContainerBuilderIdentityMismatch)] = [
      ("missing observation", nil, .observationUnavailable),
      ("role label", makeIdentity(roleLabel: "ordinary-container"), .roleLabel),
      ("plugin label", makeIdentity(pluginLabel: "other-plugin"), .pluginLabel),
      ("executable", makeIdentity(executable: "/bin/sleep"), .executable),
      ("arguments", makeIdentity(arguments: ["--debug"]), .arguments),
      ("user", makeIdentity(userID: 501), .rootUser),
      ("group", makeIdentity(groupID: 20), .rootUser),
      ("terminal", makeIdentity(terminal: true), .terminal),
      ("working directory", makeIdentity(workingDirectory: "/tmp"), .workingDirectory),
      ("capabilities", makeIdentity(addedCapabilities: ["CAP_NET_ADMIN"]), .addedCapabilities),
      (
        "mount source",
        makeIdentity(mounts: makeMounts(exportsSource: "/tmp/lookalike-builder")),
        .mounts
      ),
      (
        "extra mount",
        makeIdentity(
          mounts: makeMounts()
            + [
              ContainerBuilderMountIdentity(
                type: "virtiofs",
                source: "/tmp",
                destination: "/host",
                options: []
              )
            ]
        ),
        .mounts
      ),
      ("network", makeIdentity(networks: makeNetworks(networkID: "lookalike")), .networks),
      ("hostname", makeIdentity(networks: makeNetworks(hostname: "lookalike")), .networks),
    ]
    let destructive = ContainerBuilderSafetyAuthorization(
      allowsRecreateStoppedBuilder: true,
      allowsStopRunningBuilder: true
    )

    for (name, observedIdentity, mismatch) in cases {
      let decision = evaluate(
        snapshot: makeSnapshot(
          state: .running,
          identity: observedIdentity,
          configuration: makeConfiguration()
        ),
        authorization: destructive
      )
      #expect(decision.action == nil, Comment(rawValue: name))
      #expect(decision.reasonCode == .identityConflictDenied, Comment(rawValue: name))
      #expect(decision.errorCode == .conflict, Comment(rawValue: name))
      #expect(decision.identityMismatches.contains(mismatch), Comment(rawValue: name))
    }

    #expect(exact.roleLabel == makeRequirements().roleLabel)
    #expect(exact.pluginLabel == makeRequirements().pluginLabel)
  }

  @Test
  func labelsCannotDisguiseWrongExecutableMountOrNetwork() {
    let lookalikes = [
      makeIdentity(executable: "/usr/local/bin/not-container-builder-shim"),
      makeIdentity(mounts: makeMounts(exportsSource: "/tmp/builder")),
      makeIdentity(networks: makeNetworks(networkID: "third-party-network")),
    ]

    for identity in lookalikes {
      #expect(identity.roleLabel == makeRequirements().roleLabel)
      #expect(identity.pluginLabel == makeRequirements().pluginLabel)
      let decision = evaluate(
        snapshot: makeSnapshot(
          state: .stopped,
          identity: identity,
          configuration: makeConfiguration()
        ),
        authorization: ContainerBuilderSafetyAuthorization(
          allowsRecreateStoppedBuilder: true,
          allowsStopRunningBuilder: true
        )
      )
      #expect(decision.action == nil)
      #expect(decision.errorCode == .conflict)
    }
  }

  @Test
  func everyDesiredConfigurationFieldProducesReviewedDrift() {
    let cases:
      [(String, ContainerBuilderDesiredConfiguration?, ContainerBuilderConfigurationMismatch)] = [
        ("missing observation", nil, .observationUnavailable),
        ("image", makeConfiguration(image: "registry.example/builder:changed"), .image),
        (
          "image descriptor digest",
          makeConfiguration(imageDescriptorDigest: "sha256:changed"),
          .imageDescriptorDigest
        ),
        ("CPU", makeConfiguration(cpuCount: 8), .cpuCount),
        ("memory", makeConfiguration(memoryBytes: 8 * gibibyte), .memoryBytes),
        ("Rosetta", makeConfiguration(rosettaEnabled: false), .rosetta),
        (
          "managed colors",
          makeConfiguration(managedColorEnvironment: ["NO_COLOR=true"]),
          .managedColorEnvironment
        ),
        ("missing DNS", makeConfiguration(dns: nil), .dns),
        (
          "DNS nameservers",
          makeConfiguration(dns: makeDNS(nameservers: ["192.0.2.53"])),
          .dns
        ),
        ("DNS domain", makeConfiguration(dns: makeDNS(domain: "changed.test")), .dns),
        (
          "DNS search domains",
          makeConfiguration(dns: makeDNS(searchDomains: ["changed.test"])),
          .dns
        ),
        ("DNS options", makeConfiguration(dns: makeDNS(options: ["ndots:2"])), .dns),
        (
          "SSH agent forwarding",
          makeConfiguration(sshAgentForwarding: true),
          .sshAgentForwarding
        ),
      ]

    for (name, configuration, mismatch) in cases {
      let decision = evaluate(
        snapshot: makeSnapshot(
          state: .running,
          identity: makeIdentity(),
          configuration: configuration
        )
      )
      #expect(decision.action == nil, Comment(rawValue: name))
      #expect(decision.errorCode == .runningDrift, Comment(rawValue: name))
      #expect(decision.configurationMismatches.contains(mismatch), Comment(rawValue: name))
    }
  }

  @Test
  func dialGateRejectsReplacementBeforeDial() async {
    let expected = makeReviewedSnapshot()
    let replacement = makeReviewedSnapshot(
      creationDate: expected.creationDate.addingTimeInterval(1)
    )
    let harness = BuilderDialGateHarness(snapshots: [replacement])

    await expectDialGateError(.changedBeforeDial, expected: expected, harness: harness)
    #expect(await harness.dialCount == 0)
    #expect(await harness.closedConnections.isEmpty)
  }

  @Test
  func dialGateRejectsDescriptorDriftBeforeDial() async {
    let expected = makeReviewedSnapshot()
    let drifted = makeReviewedSnapshot(
      configuration: makeConfiguration(imageDescriptorDigest: "sha256:changed")
    )
    let harness = BuilderDialGateHarness(snapshots: [drifted])

    await expectDialGateError(.changedBeforeDial, expected: expected, harness: harness)
    #expect(await harness.dialCount == 0)
    #expect(await harness.closedConnections.isEmpty)
  }

  @Test
  func dialGateClosesConnectionForReplacementAfterDial() async {
    let expected = makeReviewedSnapshot()
    let replacement = makeReviewedSnapshot(
      creationDate: expected.creationDate.addingTimeInterval(1)
    )
    let harness = BuilderDialGateHarness(snapshots: [expected, replacement])

    await expectDialGateError(.changedAfterDial, expected: expected, harness: harness)
    #expect(await harness.dialCount == 1)
    #expect(await harness.closedConnections == [.test])
  }

  @Test
  func dialGateClosesConnectionForDNSDriftAfterDial() async {
    let expected = makeReviewedSnapshot()
    let drifted = makeReviewedSnapshot(
      configuration: makeConfiguration(dns: makeDNS(options: ["ndots:2"]))
    )
    let harness = BuilderDialGateHarness(snapshots: [expected, drifted])

    await expectDialGateError(.changedAfterDial, expected: expected, harness: harness)
    #expect(await harness.dialCount == 1)
    #expect(await harness.closedConnections == [.test])
  }

  @Test
  func allowedButWrongArgumentSetIsRosettaConfigurationDrift() {
    let identity = makeIdentity(arguments: makePinnedArguments().rosettaDisabled)
    let decision = evaluate(
      snapshot: makeSnapshot(
        state: .running,
        identity: identity,
        configuration: makeConfiguration(rosettaEnabled: true)
      )
    )

    #expect(decision.errorCode == .runningDrift)
    #expect(decision.identityMismatches.isEmpty)
    #expect(decision.configurationMismatches == [.arguments])
  }

  @Test
  func unpinnedArgumentSetIsIdentityConflictNotAuthorizedDrift() {
    let decision = evaluate(
      snapshot: makeSnapshot(
        state: .running,
        identity: makeIdentity(arguments: ["--debug", "--vsock", "--privileged-lookalike"]),
        configuration: makeConfiguration()
      ),
      authorization: ContainerBuilderSafetyAuthorization(
        allowsRecreateStoppedBuilder: true,
        allowsStopRunningBuilder: true
      )
    )

    #expect(decision.action == nil)
    #expect(decision.errorCode == .conflict)
    #expect(decision.identityMismatches == [.arguments])
  }

  @Test
  func permissionsNeverAuthorizeIdentityConflictOrIndeterminateState() {
    let authorization = ContainerBuilderSafetyAuthorization(
      allowsRecreateStoppedBuilder: true,
      allowsStopRunningBuilder: true
    )
    let cases = [
      makeSnapshot(
        state: .running,
        identity: makeIdentity(executable: "/bin/false"),
        configuration: makeConfiguration()
      ),
      makeSnapshot(
        state: .stopped,
        identity: makeIdentity(executable: "/bin/false"),
        configuration: makeConfiguration()
      ),
      makeSnapshot(state: .stopping, identity: makeIdentity(), configuration: makeConfiguration()),
      makeSnapshot(state: .unknown, identity: makeIdentity(), configuration: makeConfiguration()),
    ]

    for snapshot in cases {
      let decision = evaluate(snapshot: snapshot, authorization: authorization)
      #expect(!decision.isAllowed)
      #expect(decision.action == nil)
    }
  }

  @Test
  func policyValuesRoundTripThroughCodable() throws {
    let snapshot = makeSnapshot(
      state: .running,
      identity: makeIdentity(),
      configuration: makeConfiguration()
    )
    let decision = evaluate(snapshot: snapshot)

    let encodedSnapshot = try JSONEncoder().encode(snapshot)
    let decodedSnapshot = try JSONDecoder().decode(
      ContainerBuilderSafetySnapshot.self,
      from: encodedSnapshot
    )
    let encodedDecision = try JSONEncoder().encode(decision)
    let decodedDecision = try JSONDecoder().decode(
      ContainerBuilderSafetyDecision.self,
      from: encodedDecision
    )

    #expect(decodedSnapshot == snapshot)
    #expect(decodedDecision == decision)
    #expect(ContainerBuilderSafetyErrorCode.conflict.rawValue == "builder-conflict")
    #expect(
      ContainerBuilderSafetyReasonCode.runningDriftRecreate.rawValue
        == "builder-running-drift-recreate"
    )
  }

  private func evaluate(
    snapshot: ContainerBuilderSafetySnapshot,
    desired: ContainerBuilderDesiredConfiguration? = nil,
    authorization: ContainerBuilderSafetyAuthorization = .none
  ) -> ContainerBuilderSafetyDecision {
    ContainerBuilderSafetyPolicy.evaluate(
      snapshot: snapshot,
      identity: makeRequirements(),
      desiredConfiguration: desired ?? makeConfiguration(),
      authorization: authorization
    )
  }

  private func makeSnapshot(
    state: ContainerBuilderRuntimeState,
    identity: ContainerBuilderIdentitySnapshot?,
    configuration: ContainerBuilderDesiredConfiguration?
  ) -> ContainerBuilderSafetySnapshot {
    ContainerBuilderSafetySnapshot(
      state: state,
      identity: identity,
      configuration: configuration
    )
  }

  private func makeReviewedSnapshot(
    creationDate: Date = Date(timeIntervalSince1970: 1_000),
    configuration: ContainerBuilderDesiredConfiguration? = nil
  ) -> ContainerBuilderReviewedSnapshot {
    ContainerBuilderReviewedSnapshot(
      creationDate: creationDate,
      safety: makeSnapshot(
        state: .running,
        identity: makeIdentity(),
        configuration: configuration ?? makeConfiguration()
      )
    )
  }

  private func expectDialGateError(
    _ expectedError: ContainerBuilderDialGateError,
    expected: ContainerBuilderReviewedSnapshot,
    harness: BuilderDialGateHarness
  ) async {
    do {
      _ = try await ContainerBuilderDialGate.connect(
        expected: expected,
        current: { await harness.nextSnapshot() },
        dial: { await harness.dial() },
        close: { connection in await harness.close(connection) }
      )
      Issue.record("Expected dial gate error \(expectedError).")
    } catch let error as ContainerBuilderDialGateError {
      #expect(error == expectedError)
    } catch {
      Issue.record("Expected \(expectedError), got \(error).")
    }
  }

  private func makePinnedArguments() -> ContainerBuilderPinnedArguments {
    ContainerBuilderPinnedArguments(
      rosettaEnabled: ["--debug", "--vsock"],
      rosettaDisabled: ["--debug", "--vsock", "--enable-qemu"]
    )
  }

  private func makeRequirements() -> ContainerBuilderIdentityRequirements {
    ContainerBuilderIdentityRequirements(
      roleLabel: "builder",
      pluginLabel: "builder",
      executable: "/usr/local/bin/container-builder-shim",
      pinnedArguments: makePinnedArguments(),
      userID: 0,
      groupID: 0,
      terminal: false,
      workingDirectory: "/",
      addedCapabilities: ["ALL"],
      mounts: makeMounts(),
      networks: makeNetworks()
    )
  }

  private func makeIdentity(
    roleLabel: String? = "builder",
    pluginLabel: String? = "builder",
    executable: String = "/usr/local/bin/container-builder-shim",
    arguments: [String]? = nil,
    userID: UInt32 = 0,
    groupID: UInt32 = 0,
    terminal: Bool = false,
    workingDirectory: String = "/",
    addedCapabilities: [String] = ["ALL"],
    mounts: [ContainerBuilderMountIdentity]? = nil,
    networks: [ContainerBuilderNetworkIdentity]? = nil
  ) -> ContainerBuilderIdentitySnapshot {
    ContainerBuilderIdentitySnapshot(
      roleLabel: roleLabel,
      pluginLabel: pluginLabel,
      executable: executable,
      arguments: arguments ?? makePinnedArguments().rosettaEnabled,
      userID: userID,
      groupID: groupID,
      terminal: terminal,
      workingDirectory: workingDirectory,
      addedCapabilities: addedCapabilities,
      mounts: mounts ?? makeMounts(),
      networks: networks ?? makeNetworks()
    )
  }

  private func makeMounts(
    exportsSource: String = "/var/lib/nativecontainers/builder"
  ) -> [ContainerBuilderMountIdentity] {
    [
      ContainerBuilderMountIdentity(
        type: "tmpfs",
        source: "",
        destination: "/run",
        options: []
      ),
      ContainerBuilderMountIdentity(
        type: "virtiofs",
        source: exportsSource,
        destination: "/var/lib/container-builder-shim/exports",
        options: []
      ),
    ]
  }

  private func makeNetworks(
    networkID: String = "builtin",
    hostname: String = "buildkit"
  ) -> [ContainerBuilderNetworkIdentity] {
    [ContainerBuilderNetworkIdentity(networkID: networkID, hostname: hostname)]
  }

  private func makeConfiguration(
    image: String = "registry.example/apple/builder@sha256:pinned",
    imageDescriptorDigest: String = "sha256:pinned-index",
    cpuCount: Int = 4,
    memoryBytes: UInt64? = nil,
    rosettaEnabled: Bool = true,
    managedColorEnvironment: [String] = [
      "BUILDKIT_COLORS=run=green",
      "NO_COLOR=true",
    ],
    dns: ContainerBuilderDNSConfiguration? = ContainerBuilderDNSConfiguration(
      nameservers: [],
      domain: nil,
      searchDomains: [],
      options: []
    ),
    sshAgentForwarding: Bool = false
  ) -> ContainerBuilderDesiredConfiguration {
    ContainerBuilderDesiredConfiguration(
      image: image,
      imageDescriptorDigest: imageDescriptorDigest,
      cpuCount: cpuCount,
      memoryBytes: memoryBytes ?? (4 * gibibyte),
      rosettaEnabled: rosettaEnabled,
      managedColorEnvironment: managedColorEnvironment,
      dns: dns,
      sshAgentForwarding: sshAgentForwarding
    )
  }

  private func makeDNS(
    nameservers: [String] = [],
    domain: String? = nil,
    searchDomains: [String] = [],
    options: [String] = []
  ) -> ContainerBuilderDNSConfiguration {
    ContainerBuilderDNSConfiguration(
      nameservers: nameservers,
      domain: domain,
      searchDomains: searchDomains,
      options: options
    )
  }
}

private struct DecisionCase {
  let name: String
  let snapshot: ContainerBuilderSafetySnapshot
  let authorization: ContainerBuilderSafetyAuthorization
  let action: ContainerBuilderSafetyAction?
  let reason: ContainerBuilderSafetyReasonCode
  let error: ContainerBuilderSafetyErrorCode?
}

private struct BuilderDialGateConnection: Equatable, Sendable {
  let id: Int

  static let test = BuilderDialGateConnection(id: 1)
}

private actor BuilderDialGateHarness {
  private var snapshots: [ContainerBuilderReviewedSnapshot?]
  private(set) var dialCount = 0
  private(set) var closedConnections: [BuilderDialGateConnection] = []

  init(snapshots: [ContainerBuilderReviewedSnapshot?]) {
    self.snapshots = snapshots
  }

  func nextSnapshot() -> ContainerBuilderReviewedSnapshot? {
    guard !snapshots.isEmpty else { return nil }
    return snapshots.removeFirst()
  }

  func dial() -> BuilderDialGateConnection {
    dialCount += 1
    return .test
  }

  func close(_ connection: BuilderDialGateConnection) {
    closedConnections.append(connection)
  }
}
