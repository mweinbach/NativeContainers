import Darwin
import Foundation
import Testing

@testable import NativeContainers

@Suite(.serialized)
struct ComposeOperationJournalTests {
  @Test
  func persistsOnlyRedactedPlanSummaryAndDurablyPublishesOneRecord() async throws {
    let syncer = RecordingJournalDurabilitySyncer()
    let fixture = try JournalFixture(durabilitySyncer: syncer)
    defer { fixture.remove() }

    let operationID = UUID(uuidString: "11111111-2222-3333-4444-555555555555")!
    let entry = ComposeOperationJournalEntry(
      operationID: operationID,
      plan: sensitivePlan(),
      preparedAt: Date(timeIntervalSince1970: 1_750_000_000)
    )

    try await fixture.journal.persistPending(entry)

    let recordURL = fixture.recordURL(for: operationID)
    let encoded = try Data(contentsOf: recordURL)
    let json = try #require(String(data: encoded, encoding: .utf8))
    for secret in [
      "customer-secret-directory",
      "secret-compose.yaml",
      "registry.example.com/private-token",
      "secret-profile",
      "container-secret",
      "volume-secret",
      "network-secret",
      "orphan-secret",
      "preserved-secret",
      "secret-version",
    ] {
      #expect(!json.contains(secret))
    }
    #expect(!json.contains("sourcePath"))
    #expect(!json.contains("commandOutput"))
    #expect(!json.contains("environmentVariables"))

    let entries = try FileManager.default.contentsOfDirectory(atPath: fixture.directoryURL.path)
    #expect(entries == [ComposeOperationJournal.recordFilename(for: operationID)])

    var metadata = stat()
    #expect(Darwin.lstat(recordURL.path, &metadata) == 0)
    #expect(metadata.st_uid == Darwin.geteuid())
    #expect(metadata.st_mode & mode_t(0o777) == mode_t(0o600))
    #expect(metadata.st_nlink == 1)

    let snapshots = try await fixture.journal.pendingRecoverySnapshots()
    let snapshot = try #require(snapshots.first)
    #expect(snapshots.count == 1)
    #expect(snapshot.operationID == operationID)
    #expect(snapshot.planID == entry.planID)
    #expect(snapshot.action == .down)
    #expect(snapshot.projectName == "private-project")
    #expect(snapshot.sourceFileSHA256 == String(repeating: "a", count: 64))
    #expect(snapshot.composeBinarySHA256 == String(repeating: "d", count: 64))
    #expect(snapshot.composeSourceRevision == "source-revision")
    #expect(snapshot.environmentSHA256 == String(repeating: "e", count: 64))
    #expect(snapshot.phase == .prepared)
    #expect(snapshot.completedContainerIDs.isEmpty)
    #expect(snapshot.completedNetworkNames.isEmpty)
    #expect(snapshot.completedVolumeNames.isEmpty)
    #expect(snapshot.removeOrphans)
    #expect(snapshot.removeVolumes)
    #expect(snapshot.affectedContainerCount == 1)
    #expect(snapshot.affectedVolumeCount == 1)
    #expect(snapshot.affectedNetworkCount == 1)
    #expect(snapshot.orphanContainerCount == 1)

    let events = syncer.events
    let fileSyncIndex = try #require(events.firstIndex(of: .file))
    let finalDirectorySyncIndex = try #require(events.lastIndex(of: .directory))
    #expect(fileSyncIndex < finalDirectorySyncIndex)
  }

  @Test
  func progressUpdatesAreAtomicDurableAndVisibleToRecovery() async throws {
    let syncer = RecordingJournalDurabilitySyncer()
    let fixture = try JournalFixture(durabilitySyncer: syncer)
    defer { fixture.remove() }
    let entry = sampleEntry(action: .down, removeOrphans: true, removeVolumes: true)
    try await fixture.journal.persistPending(entry)
    let recordURL = fixture.recordURL(for: entry.operationID)
    let preparedData = try Data(contentsOf: recordURL)
    syncer.reset()

    try await fixture.journal.updatePending(
      operationID: entry.operationID,
      expectedPhase: .prepared,
      progress: ComposeOperationJournalProgress(
        phase: .executing,
        completedStepTokens: ["container-0001"]
      )
    )

    #expect(syncer.events == [.file, .directory])
    #expect(try Data(contentsOf: recordURL) != preparedData)
    #expect(
      try FileManager.default.contentsOfDirectory(atPath: fixture.directoryURL.path)
        == [ComposeOperationJournal.recordFilename(for: entry.operationID)]
    )

    syncer.reset()
    try await fixture.journal.updatePending(
      operationID: entry.operationID,
      expectedPhase: .executing,
      progress: ComposeOperationJournalProgress(
        phase: .verifying,
        completedStepTokens: [
          "container-0001",
          "container-0002",
          "container-0003",
          "network-0001",
          "volume-0001",
          "volume-0002",
        ]
      )
    )
    #expect(syncer.events == [.file, .directory])

    let recoveredJournal = ComposeOperationJournal(directoryURL: fixture.directoryURL)
    let snapshot = try #require(
      try await recoveredJournal.pendingRecoverySnapshots().first
    )
    #expect(snapshot.phase == .verifying)
    #expect(
      snapshot.completedContainerIDs
        == ["container-0001", "container-0002", "container-0003"]
    )
    #expect(snapshot.completedNetworkNames == ["network-0001"])
    #expect(
      snapshot.completedVolumeNames == ["volume-0001", "volume-0002"]
    )
    #expect(snapshot.recoveryDisposition == .manualReviewRequired)
    #expect(!snapshot.allowsAutomaticExecution)
  }

  @Test
  func progressCannotRegressOrForgetDurableCompletedResources() async throws {
    let fixture = try JournalFixture()
    defer { fixture.remove() }
    let entry = sampleEntry()
    try await fixture.journal.persistPending(entry)
    try await fixture.journal.updatePending(
      operationID: entry.operationID,
      expectedPhase: .prepared,
      progress: ComposeOperationJournalProgress(
        phase: .executing,
        completedStepTokens: ["container-0001"]
      )
    )

    await #expect(throws: ComposeOperationJournalError.self) {
      try await fixture.journal.updatePending(
        operationID: entry.operationID,
        expectedPhase: .executing,
        progress: ComposeOperationJournalProgress(phase: .prepared)
      )
    }
    await #expect(throws: ComposeOperationJournalError.self) {
      try await fixture.journal.updatePending(
        operationID: entry.operationID,
        expectedPhase: .executing,
        progress: ComposeOperationJournalProgress(phase: .executing)
      )
    }

    let snapshot = try #require(
      try await fixture.journal.pendingRecoverySnapshots().first
    )
    #expect(snapshot.phase == .executing)
    #expect(snapshot.completedContainerIDs == ["container-0001"])
  }

  @Test
  func destructiveRecoverySnapshotIsReadOnlyAndCannotAuthorizeAutomaticExecution() async throws {
    let fixture = try JournalFixture()
    defer { fixture.remove() }
    let entry = sampleEntry(action: .down, removeOrphans: true, removeVolumes: true)
    try await fixture.journal.persistPending(entry)

    let recordURL = fixture.recordURL(for: entry.operationID)
    let originalData = try Data(contentsOf: recordURL)
    let originalEntries = try FileManager.default.contentsOfDirectory(
      atPath: fixture.directoryURL.path
    )

    let readSyncer = RecordingJournalDurabilitySyncer()
    let recoveredJournal = ComposeOperationJournal(
      directoryURL: fixture.directoryURL,
      durabilitySyncer: readSyncer
    )
    let firstRead = try await recoveredJournal.pendingRecoverySnapshots()
    let secondRead = try await recoveredJournal.pendingRecoverySnapshots()
    let snapshot = try #require(firstRead.first)

    #expect(firstRead == secondRead)
    #expect(snapshot.action == .down)
    #expect(snapshot.removeOrphans)
    #expect(snapshot.removeVolumes)
    #expect(snapshot.recoveryDisposition == .manualReviewRequired)
    #expect(!snapshot.allowsAutomaticExecution)
    #expect(readSyncer.events.isEmpty)
    #expect(try Data(contentsOf: recordURL) == originalData)
    #expect(
      try FileManager.default.contentsOfDirectory(atPath: fixture.directoryURL.path)
        == originalEntries
    )

    try await recoveredJournal.discardPendingAfterReview(operationID: entry.operationID)
    #expect(!FileManager.default.fileExists(atPath: recordURL.path))
    #expect(readSyncer.events == [.directory])
  }

  @Test
  func fileSyncFailureNeverPublishesAPartialRecord() async throws {
    let fixture = try JournalFixture(durabilitySyncer: FailingFileJournalDurabilitySyncer())
    defer { fixture.remove() }

    await #expect(throws: ComposeOperationJournalError.self) {
      try await fixture.journal.persistPending(sampleEntry())
    }

    let entries = try FileManager.default.contentsOfDirectory(atPath: fixture.directoryURL.path)
    #expect(entries.isEmpty)
  }

  @Test
  func duplicateOperationRefusesToReplaceTheDurableRecord() async throws {
    let fixture = try JournalFixture()
    defer { fixture.remove() }
    let original = sampleEntry()
    try await fixture.journal.persistPending(original)
    let recordURL = fixture.recordURL(for: original.operationID)
    let originalData = try Data(contentsOf: recordURL)

    let replacement = ComposeOperationJournalEntry(
      operationID: original.operationID,
      planID: UUID(),
      action: .up,
      projectName: "different-project",
      preparedAt: Date(timeIntervalSince1970: 1_760_000_000),
      sourceFileSHA256: String(repeating: "d", count: 64),
      fullConfigurationSHA256: String(repeating: "e", count: 64),
      activeConfigurationSHA256: String(repeating: "f", count: 64),
      composeBinarySHA256: String(repeating: "a", count: 64),
      composeSourceRevision: "source-revision",
      environmentSHA256: String(repeating: "b", count: 64),
      removeOrphans: false,
      removeVolumes: false,
      affectedContainerCount: 0,
      affectedVolumeCount: 0,
      affectedNetworkCount: 0,
      orphanContainerCount: 0,
      plannedStepTokens: []
    )

    await #expect(
      throws: ComposeOperationJournalError.recordAlreadyExists(original.operationID)
    ) {
      try await fixture.journal.persistPending(replacement)
    }
    #expect(try Data(contentsOf: recordURL) == originalData)
  }

  @Test
  func rejectsSymbolicJournalDirectory() async throws {
    let rootURL = try makeOwnerPrivateTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: rootURL) }

    let actualURL = rootURL.appending(path: "Actual", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(
      at: actualURL,
      withIntermediateDirectories: false,
      attributes: [.posixPermissions: 0o700]
    )
    let journalURL = rootURL.appending(path: "Journal", directoryHint: .isDirectory)
    try FileManager.default.createSymbolicLink(at: journalURL, withDestinationURL: actualURL)

    let journal = ComposeOperationJournal(directoryURL: journalURL)
    await #expect(throws: ComposeOperationJournalError.self) {
      _ = try await journal.pendingRecoverySnapshots()
    }
  }

  @Test
  func rejectsForeignOwnedJournalDirectory() async throws {
    let rootURL = try makeOwnerPrivateTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: rootURL) }
    let journalURL = rootURL.appending(path: "Journal", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(
      at: journalURL,
      withIntermediateDirectories: false,
      attributes: [.posixPermissions: 0o700]
    )

    let currentUserID = Darwin.geteuid()
    let foreignUserID = currentUserID == uid_t.max ? currentUserID - 1 : currentUserID + 1
    let journal = ComposeOperationJournal(
      directoryURL: journalURL,
      effectiveUserID: foreignUserID
    )
    await #expect(throws: ComposeOperationJournalError.self) {
      _ = try await journal.pendingRecoverySnapshots()
    }
  }

  @Test
  func rejectsGroupOrWorldAccessibleJournalDirectory() async throws {
    for permissions in [mode_t(0o770), mode_t(0o707)] {
      let rootURL = try makeOwnerPrivateTemporaryDirectory()
      defer { try? FileManager.default.removeItem(at: rootURL) }
      let journalURL = rootURL.appending(path: "Journal", directoryHint: .isDirectory)
      try FileManager.default.createDirectory(
        at: journalURL,
        withIntermediateDirectories: false,
        attributes: [.posixPermissions: NSNumber(value: permissions)]
      )
      #expect(Darwin.chmod(journalURL.path, permissions) == 0)

      let journal = ComposeOperationJournal(directoryURL: journalURL)
      await #expect(throws: ComposeOperationJournalError.self) {
        _ = try await journal.pendingRecoverySnapshots()
      }
    }
  }

  @Test
  func rejectsSymbolicRecord() async throws {
    let fixture = try JournalFixture()
    defer { fixture.remove() }
    let entry = sampleEntry()
    try await fixture.journal.persistPending(entry)
    let recordURL = fixture.recordURL(for: entry.operationID)
    try FileManager.default.removeItem(at: recordURL)

    let targetURL = fixture.rootURL.appending(path: "target.json")
    try Data("{}".utf8).write(to: targetURL)
    #expect(Darwin.chmod(targetURL.path, mode_t(0o600)) == 0)
    try FileManager.default.createSymbolicLink(at: recordURL, withDestinationURL: targetURL)

    await #expect(throws: ComposeOperationJournalError.self) {
      _ = try await fixture.journal.pendingRecoverySnapshots()
    }
  }

  @Test
  func rejectsGroupOrWorldAccessibleRecords() async throws {
    for permissions in [mode_t(0o620), mode_t(0o602)] {
      let fixture = try JournalFixture()
      defer { fixture.remove() }
      let entry = sampleEntry(operationID: UUID())
      try await fixture.journal.persistPending(entry)
      let recordURL = fixture.recordURL(for: entry.operationID)
      #expect(Darwin.chmod(recordURL.path, permissions) == 0)

      await #expect(throws: ComposeOperationJournalError.self) {
        _ = try await fixture.journal.pendingRecoverySnapshots()
      }
    }
  }

  @Test
  func rejectsHardLinkedRecords() async throws {
    let fixture = try JournalFixture()
    defer { fixture.remove() }
    let entry = sampleEntry()
    try await fixture.journal.persistPending(entry)
    let recordURL = fixture.recordURL(for: entry.operationID)
    let aliasURL = fixture.directoryURL.appending(path: "record-alias")
    #expect(Darwin.link(recordURL.path, aliasURL.path) == 0)

    await #expect(throws: ComposeOperationJournalError.self) {
      _ = try await fixture.journal.pendingRecoverySnapshots()
    }
  }

  @Test
  func rejectsOversizedRecordsBeforeDecoding() async throws {
    let fixture = try JournalFixture()
    defer { fixture.remove() }
    try await fixture.journal.persistPending(sampleEntry())
    let oversizedID = UUID(uuidString: "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee")!
    let oversizedURL = fixture.recordURL(for: oversizedID)
    try Data(
      repeating: 0x41,
      count: Int(ComposeOperationJournal.maximumRecordByteCount + 1)
    ).write(to: oversizedURL)
    #expect(Darwin.chmod(oversizedURL.path, mode_t(0o600)) == 0)

    await #expect(throws: ComposeOperationJournalError.self) {
      _ = try await fixture.journal.pendingRecoverySnapshots()
    }
  }
}

private enum JournalSyncEvent: Equatable {
  case file
  case directory
}

private final class RecordingJournalDurabilitySyncer:
  ComposeOperationJournalDurabilitySyncing,
  @unchecked Sendable
{
  private let lock = NSLock()
  private var storedEvents: [JournalSyncEvent] = []

  var events: [JournalSyncEvent] {
    lock.lock()
    defer { lock.unlock() }
    return storedEvents
  }

  func reset() {
    lock.lock()
    storedEvents.removeAll()
    lock.unlock()
  }

  func syncFile(descriptor: Int32) throws {
    lock.lock()
    storedEvents.append(.file)
    lock.unlock()
  }

  func syncDirectory(descriptor: Int32) throws {
    lock.lock()
    storedEvents.append(.directory)
    lock.unlock()
  }
}

private struct FailingFileJournalDurabilitySyncer:
  ComposeOperationJournalDurabilitySyncing
{
  func syncFile(descriptor: Int32) throws {
    throw ComposeOperationJournalError.ioFailure(
      operation: "synchronize a pending record",
      code: EIO
    )
  }

  func syncDirectory(descriptor: Int32) throws {}
}

private struct JournalFixture {
  let rootURL: URL
  let directoryURL: URL
  let journal: ComposeOperationJournal

  init(
    durabilitySyncer: any ComposeOperationJournalDurabilitySyncing =
      DarwinComposeOperationJournalDurabilitySyncer()
  ) throws {
    rootURL = try makeOwnerPrivateTemporaryDirectory()
    directoryURL = rootURL.appending(path: "Journal", directoryHint: .isDirectory)
    journal = ComposeOperationJournal(
      directoryURL: directoryURL,
      durabilitySyncer: durabilitySyncer
    )
  }

  func recordURL(for operationID: UUID) -> URL {
    directoryURL.appending(
      path: ComposeOperationJournal.recordFilename(for: operationID),
      directoryHint: .notDirectory
    )
  }

  func remove() {
    try? FileManager.default.removeItem(at: rootURL)
  }
}

private func makeOwnerPrivateTemporaryDirectory() throws -> URL {
  let url = FileManager.default.temporaryDirectory.appending(
    path: "NativeContainers-ComposeJournalTests-\(UUID().uuidString)",
    directoryHint: .isDirectory
  )
  try FileManager.default.createDirectory(
    at: url,
    withIntermediateDirectories: false,
    attributes: [.posixPermissions: 0o700]
  )
  guard Darwin.chmod(url.path, mode_t(0o700)) == 0 else {
    throw ComposeOperationJournalError.ioFailure(
      operation: "secure a test directory",
      code: errno
    )
  }
  return url
}

private func sampleEntry(
  operationID: UUID = UUID(uuidString: "99999999-8888-7777-6666-555555555555")!,
  action: ComposeProjectLifecycleAction = .up,
  removeOrphans: Bool = false,
  removeVolumes: Bool = false
) -> ComposeOperationJournalEntry {
  ComposeOperationJournalEntry(
    operationID: operationID,
    planID: UUID(uuidString: "12345678-1234-1234-1234-123456789abc")!,
    action: action,
    projectName: "sample-project",
    preparedAt: Date(timeIntervalSince1970: 1_750_000_000),
    sourceFileSHA256: String(repeating: "a", count: 64),
    fullConfigurationSHA256: String(repeating: "b", count: 64),
    activeConfigurationSHA256: String(repeating: "c", count: 64),
    composeBinarySHA256: String(repeating: "d", count: 64),
    composeSourceRevision: "source-revision",
    environmentSHA256: String(repeating: "e", count: 64),
    removeOrphans: removeOrphans,
    removeVolumes: removeVolumes,
    affectedContainerCount: 3,
    affectedVolumeCount: 2,
    affectedNetworkCount: 1,
    orphanContainerCount: 1,
    plannedStepTokens: [
      "container-0001",
      "container-0002",
      "container-0003",
      "network-0001",
      "volume-0001",
      "volume-0002",
    ]
  )
}

private func sensitivePlan() -> ComposeProjectPlan {
  let sourceIdentity = ComposeProjectSourceFileIdentity(
    device: 1,
    inode: 2,
    owner: Darwin.geteuid(),
    permissions: 0o600,
    byteCount: 123,
    modificationSeconds: 1,
    modificationNanoseconds: 2,
    changeSeconds: 3,
    changeNanoseconds: 4,
    sha256: String(repeating: "a", count: 64)
  )
  let service = ComposeDesiredService(
    name: "secret-service",
    imageReference: "registry.example.com/private-token",
    replicaCount: 1,
    profiles: ["secret-profile"],
    dependencyNames: [],
    configurationHash: String(repeating: "d", count: 64),
    volumeNames: ["volume-secret"],
    networkNames: ["network-secret"],
    publishedPortCount: 0
  )
  func identity(_ id: String) -> ComposeProjectContainerIdentity {
    ComposeProjectContainerIdentity(
      ContainerRecord(
        id: id,
        imageReference: "registry.example.com/private-token",
        imageDigest: "sha256:private-image",
        platform: "linux/arm64",
        state: .stopped,
        ipAddress: nil,
        createdAt: Date(timeIntervalSince1970: 1_749_999_000),
        startedAt: nil,
        cpuCount: 2,
        memoryBytes: 1_024,
        ports: [],
        labels: [ComposeLabelKey.project: "private-project"]
      )
    )
  }
  let containerIdentity = identity("container-secret")
  let orphanIdentity = identity("orphan-secret")

  return ComposeProjectPlan(
    id: UUID(uuidString: "abcdefab-cdef-abcd-efab-cdefabcdefab")!,
    generatedAt: Date(timeIntervalSince1970: 1_749_999_000),
    options: ComposeProjectReviewOptions(
      action: .down,
      projectName: "private-project",
      profiles: ["secret-profile"],
      removeOrphans: true,
      removeVolumes: true
    ),
    source: ComposeProjectSourceSummary(
      directoryName: "customer-secret-directory",
      fileName: "secret-compose.yaml",
      fileIdentity: sourceIdentity
    ),
    desiredState: ComposeDesiredState(
      projectName: "private-project",
      declaredServiceNames: ["secret-service"],
      serviceDependencies: ["secret-service": []],
      activeServices: [service],
      volumes: [
        ComposeDesiredResource(
          kind: .volume,
          logicalName: "volume-secret",
          runtimeName: "private-project_volume-secret",
          isExternal: false,
          isActive: true
        )
      ],
      networks: [
        ComposeDesiredResource(
          kind: .network,
          logicalName: "network-secret",
          runtimeName: "private-project_network-secret",
          isExternal: false,
          isActive: true
        )
      ]
    ),
    fullConfigurationSHA256: String(repeating: "b", count: 64),
    activeConfigurationSHA256: String(repeating: "c", count: 64),
    composeReleaseVersion: "secret-version",
    composeBinarySHA256: String(repeating: "d", count: 64),
    composeSourceRevision: "source-revision",
    environmentSHA256: String(repeating: "e", count: 64),
    serviceConfigurationHashes: [
      "secret-service": String(repeating: "d", count: 64)
    ],
    observedIdentity: .empty,
    issues: [],
    containerActions: [
      ComposeProjectContainerAction(
        stepID: .container(1),
        operation: .removeDeclared,
        serviceName: "secret-service",
        replicaNumber: 1,
        expectedIdentity: containerIdentity
      )
    ],
    volumeActions: [
      ComposeProjectVolumeAction(
        stepID: .volume(1),
        operation: .removeManaged,
        logicalName: "volume-secret",
        runtimeName: "volume-secret",
        expectedIdentity: nil
      )
    ],
    networkActions: [
      ComposeProjectNetworkAction(
        stepID: .network(1),
        operation: .removeManaged,
        logicalName: "network-secret",
        runtimeName: "network-secret",
        expectedIdentity: nil
      )
    ],
    orphanContainers: [orphanIdentity],
    preservedResources: [.absent(kind: .network, name: "preserved-secret")]
  )
}
